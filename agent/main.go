// Agent-side MAA setup for TRUF.NETWORK.
//
// Two commands, run in this order:
//
//	go run . keygen              # once. Creates the agent key. Never share it.
//	go run . create-rule         # registers the rule, prints the Rule ID
//	go run . derive <owner-0x..> # prints the expected agent wallet address
//
// Then the four trading commands, one per action the rule allows:
// buy, sell, split (mint a pair and list the NO side), and cancel.
//
// The AGENT key created here is the restricted key. It can place and cancel
// orders as the agent wallet and can never move funds out. The OWNER key is the
// user's and never touches this machine.
//
// Creating a rule is fund-free at the protocol level (no wrapper fee, no
// transaction event) and a rule nobody joins is inert, so this is safe to run
// before any money exists.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/trufnetwork/kwil-db/core/crypto"
	"github.com/trufnetwork/kwil-db/core/crypto/auth"
	kwilTypes "github.com/trufnetwork/kwil-db/core/types"
	"github.com/trufnetwork/sdk-go/core/contractsapi"
	"github.com/trufnetwork/sdk-go/core/tnclient"
	"github.com/trufnetwork/sdk-go/core/types"
	"github.com/trufnetwork/sdk-go/core/util"
)

// Files live next to this binary, so `./agent/agent keygen` from the repo root
// and `./agent keygen` from inside agent/ write the same agent/agent.key.
// The node endpoint comes from TN_RPC, else TN_RPC_PORT, else .tn-env at the
// repo root (written by scripts/ports.sh), else the upstream default.
var (
	endpoint string
	keyFile  string // 0600, gitignored, never printed
	ruleFile string
)

func init() {
	dir := "."
	if exe, err := os.Executable(); err == nil {
		dir = filepath.Dir(exe)
	}
	keyFile = filepath.Join(dir, "agent.key")
	ruleFile = filepath.Join(dir, "rule.id")

	port := os.Getenv("TN_RPC_PORT")
	if port == "" {
		if b, err := os.ReadFile(filepath.Join(dir, "..", ".tn-env")); err == nil {
			for _, line := range strings.Split(string(b), "\n") {
				if v, ok := strings.CutPrefix(line, "TN_RPC_PORT="); ok {
					port = strings.TrimSpace(v)
				}
			}
		}
	}
	if port == "" {
		port = "8484"
	}
	endpoint = "http://127.0.0.1:" + port
	if e := os.Getenv("TN_RPC"); e != "" {
		endpoint = e
	}
}

// The canonical liquidity-agent allow-list. Exactly four actions, all in `main`.
// Deliberately absent: every withdraw/bridge primitive, create_market and
// settle_market. Never add maa_join_and_fund: it moves funds.
var allowed = []string{
	"place_buy_order",
	"place_sell_order",
	"place_split_limit_order",
	"cancel_order",
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: keygen | create-rule | derive <owner> | decode <hex> |")
		fmt.Println("       buy    <maa> <order-book> <yes|no> <price-cents> <shares>")
		fmt.Println("       sell   <maa> <order-book> <yes|no> <price-cents> <shares>")
		fmt.Println("       split  <maa> <order-book> <yes-price-cents> <pairs>")
		fmt.Println("       cancel <maa> <order-book> <yes|no> <buy|sell> <price-cents>")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "keygen":
		err = keygen()
	case "create-rule":
		err = createRule()
	case "buy":
		if len(os.Args) < 7 {
			err = fmt.Errorf("buy <maa-address> <order-book-id> <yes|no> <price-cents> <shares>")
		} else {
			err = buy(os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6])
		}
	case "sell":
		if len(os.Args) < 7 {
			err = fmt.Errorf("sell <maa-address> <order-book-id> <yes|no> <price-cents> <shares>")
		} else {
			err = sell(os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6])
		}
	case "split":
		if len(os.Args) < 6 {
			err = fmt.Errorf("split <maa-address> <order-book-id> <yes-price-cents> <pairs>")
		} else {
			err = split(os.Args[2], os.Args[3], os.Args[4], os.Args[5])
		}
	case "cancel":
		if len(os.Args) < 7 {
			err = fmt.Errorf("cancel <maa-address> <order-book-id> <yes|no> <buy|sell> <price-cents>")
		} else {
			err = cancel(os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6])
		}
	case "decode":
		if len(os.Args) < 3 {
			err = fmt.Errorf("decode needs the hex query_components")
		} else {
			err = decodeMarket(os.Args[2])
		}
	case "derive":
		if len(os.Args) < 3 {
			err = fmt.Errorf("derive needs the owner's 0x address")
		} else {
			err = derive(os.Args[2])
		}
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// keygen creates the agent's secp256k1 key once. Refuses to overwrite: losing
// this key means losing control of the agent side of an existing rule.
func keygen() error {
	if _, err := os.Stat(keyFile); err == nil {
		return fmt.Errorf("%s already exists, refusing to overwrite", keyFile)
	}
	generated, _, err := crypto.GenerateSecp256k1Key(rand.Reader)
	if err != nil {
		return err
	}
	priv, ok := generated.(*crypto.Secp256k1PrivateKey)
	if !ok {
		return fmt.Errorf("unexpected key type %T", generated)
	}
	if err := os.WriteFile(keyFile, []byte(hex.EncodeToString(priv.Bytes())), 0o600); err != nil {
		return err
	}
	addr, err := agentAddress(priv)
	if err != nil {
		return err
	}
	fmt.Printf("agent key written to %s (0600)\n", keyFile)
	fmt.Printf("agent address: %s\n", addr)
	fmt.Println("\nThis key is the agent's identity. It can trade and can never withdraw.")
	fmt.Println("Do not share it and do not commit it.")
	return nil
}

func loadKey() (*crypto.Secp256k1PrivateKey, error) {
	b, err := os.ReadFile(keyFile)
	if err != nil {
		return nil, fmt.Errorf("no agent key: run `keygen` first (%w)", err)
	}
	raw, err := hex.DecodeString(strings.TrimSpace(string(b)))
	if err != nil {
		return nil, err
	}
	return crypto.Secp256k1PrivateKeyFromHex(hex.EncodeToString(raw))
}

func agentAddress(priv *crypto.Secp256k1PrivateKey) (string, error) {
	signer := &auth.EthPersonalSigner{Key: *priv}
	a, err := util.NewEthereumAddressFromBytes(signer.CompactID())
	if err != nil {
		return "", err
	}
	return a.Address(), nil
}

func client(ctx context.Context) (*tnclient.Client, *crypto.Secp256k1PrivateKey, error) {
	priv, err := loadKey()
	if err != nil {
		return nil, nil, err
	}
	c, err := tnclient.NewClient(ctx, endpoint,
		tnclient.WithSigner(&auth.EthPersonalSigner{Key: *priv}))
	return c, priv, err
}

// createRule registers the allow-list on chain with zero commission.
func createRule() error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	c, priv, err := client(ctx)
	if err != nil {
		return err
	}
	addr, _ := agentAddress(priv)

	ns := make([]string, len(allowed))
	bh := make([][]byte, len(allowed))
	for i := range allowed {
		ns[i] = "main" // body hashes left nil: unpinned
	}

	actions, err := c.LoadActions()
	if err != nil {
		return err
	}

	fmt.Printf("agent address : %s\n", addr)
	fmt.Printf("allow-list    : %s\n", strings.Join(allowed, ", "))
	fmt.Printf("commission    : 0 bps\n\n")

	ruleID, tx, err := actions.CreateAgentRule(ctx, types.MAACreateRuleInput{
		FeeMode:    "bps",
		FeeBps:     0, // zero commission: owner-operated agent
		FeeFlat:    "0",
		Namespaces: ns,
		Actions:    allowed,
		BodyHashes: bh,
	})
	if err != nil {
		return fmt.Errorf("create rule: %w", err)
	}
	fmt.Printf("tx: %s\nhttps://trufscan.io/tx/%s\nwaiting for inclusion...\n", tx, tx)
	h, err := kwilTypes.NewHashFromString(tx)
	if err != nil {
		return fmt.Errorf("parse tx hash %q: %w", tx, err)
	}
	res, err := c.WaitForTx(ctx, h, 2*time.Second)
	if err != nil {
		return fmt.Errorf("wait for tx: %w", err)
	}
	if res.Result.Code != uint32(kwilTypes.CodeOk) {
		return fmt.Errorf("tx failed (code %d): %s", res.Result.Code, res.Result.Log)
	}

	id := hex.EncodeToString(ruleID)
	if err := os.WriteFile(ruleFile, []byte(id), 0o644); err != nil {
		return err
	}
	fmt.Printf("\nRULE ID: 0x%s\n", id)
	fmt.Println("(the 0x prefix is REQUIRED by the account app's Connect Agent form)")
	fmt.Println("\nGive the Rule ID to the owner. Then, once they send you their")
	fmt.Println("wallet address, run:  go run . derive <their-0x-address>")
	return nil
}

// derive computes the agent wallet address the owner will see when they link
// the rule. It is a pure function of (owner, agent, ruleID), so both sides
// compute it independently and compare. That comparison is what protects the
// owner from funding an address an operator simply asserted.
func derive(ownerHex string) error {
	priv, err := loadKey()
	if err != nil {
		return err
	}
	rb, err := os.ReadFile(ruleFile)
	if err != nil {
		return fmt.Errorf("no rule id: run `create-rule` first (%w)", err)
	}
	ruleID, err := hex.DecodeString(strings.TrimPrefix(strings.TrimSpace(string(rb)), "0x"))
	if err != nil {
		return err
	}
	owner, err := util.NewEthereumAddressFromString(strings.TrimSpace(ownerHex))
	if err != nil {
		return fmt.Errorf("bad owner address: %w", err)
	}
	signer := &auth.EthPersonalSigner{Key: *priv}
	agent, err := util.NewEthereumAddressFromBytes(signer.CompactID())
	if err != nil {
		return err
	}
	maa, err := util.DeriveMAAAddress(owner.Bytes(), agent.Bytes(), ruleID)
	if err != nil {
		return fmt.Errorf("derive: %w", err)
	}
	a, err := util.NewEthereumAddressFromBytes(maa)
	if err != nil {
		return err
	}
	fmt.Printf("owner   : %s\n", owner.Address())
	fmt.Printf("agent   : %s\n", agent.Address())
	fmt.Printf("rule    : 0x%s\n\n", hex.EncodeToString(ruleID))
	fmt.Printf("EXPECTED AGENT WALLET: %s\n", a.Address())
	fmt.Println("\nSend this to the owner. They must see the SAME address on the")
	fmt.Println("website in Step 3 before funding anything.")
	return nil
}

// decodeMarket turns query_components into the human-readable market terms:
// type, thresholds, the stream it observes, and the timestamp it observes it
// at. contractsapi.DecodeMarketData is a pure function, so this needs no node.
func decodeMarket(hexstr string) error {
	raw, err := hex.DecodeString(strings.TrimPrefix(strings.TrimSpace(hexstr), "0x"))
	if err != nil {
		return fmt.Errorf("bad hex: %w", err)
	}
	d, err := contractsapi.DecodeMarketData(raw)
	if err != nil {
		return fmt.Errorf("decode: %w", err)
	}
	out, _ := json.Marshal(d)
	fmt.Println(string(out))
	return nil
}

// buy places a limit buy order AS THE AGENT WALLET, through the maa_exec route.
// The agent signs, the node rewrites @caller to the MAA, and collateral is
// locked from the MAA's own balance. The agent can never move those funds out.
//
//	place_buy_order($query_id INT, $outcome BOOL, $price INT, $amount INT8)
//
// price is cents, 1..99. amount is a share count.
// parseSide maps yes/no to the outcome flag the actions take.
func parseSide(side string) (bool, error) {
	switch strings.ToLower(side) {
	case "yes":
		return true, nil
	case "no":
		return false, nil
	}
	return false, fmt.Errorf("side must be yes or no, got %q", side)
}

func parseCents(priceStr string) (int, error) {
	price, err := strconv.Atoi(priceStr)
	if err != nil {
		return 0, fmt.Errorf("price: %w", err)
	}
	if price < 1 || price > 99 {
		return 0, fmt.Errorf("price must be 1..99 cents, got %d", price)
	}
	return price, nil
}

func parseShares(amountStr string) (int64, error) {
	amount, err := strconv.ParseInt(amountStr, 10, 64)
	if err != nil || amount <= 0 {
		return 0, fmt.Errorf("shares must be a positive integer")
	}
	return amount, nil
}

// buy: place_buy_order. Locks amount*price/100 USDC from the agent wallet.
func buy(maaHex, bookStr, side, priceStr, amountStr string) error {
	book, err := strconv.Atoi(bookStr)
	if err != nil {
		return fmt.Errorf("order book id: %w", err)
	}
	price, err := parseCents(priceStr)
	if err != nil {
		return err
	}
	amount, err := parseShares(amountStr)
	if err != nil {
		return err
	}
	outcome, err := parseSide(side)
	if err != nil {
		return err
	}
	return execute(maaHex, "place_buy_order", []any{book, outcome, price, amount},
		fmt.Sprintf("BUY %d %s @ %dc on order book %d", amount, strings.ToUpper(side), price, book),
		fmt.Sprintf("%.2f USDC locked from the agent wallet", float64(amount)*float64(price)/100.0))
}

// sell: place_sell_order. Lists shares the wallet already holds. Nothing is
// locked, because the shares themselves are the collateral.
func sell(maaHex, bookStr, side, priceStr, amountStr string) error {
	book, err := strconv.Atoi(bookStr)
	if err != nil {
		return fmt.Errorf("order book id: %w", err)
	}
	price, err := parseCents(priceStr)
	if err != nil {
		return err
	}
	amount, err := parseShares(amountStr)
	if err != nil {
		return err
	}
	outcome, err := parseSide(side)
	if err != nil {
		return err
	}
	return execute(maaHex, "place_sell_order", []any{book, outcome, price, amount},
		fmt.Sprintf("SELL %d %s @ %dc on order book %d", amount, strings.ToUpper(side), price, book),
		"no collateral, the shares are already held")
}

// split: place_split_limit_order. Mints amount YES+NO pairs for $1.00 each,
// keeps the YES and lists the NO at 100-yesPrice. This is how a maker quotes.
func split(maaHex, bookStr, priceStr, amountStr string) error {
	book, err := strconv.Atoi(bookStr)
	if err != nil {
		return fmt.Errorf("order book id: %w", err)
	}
	price, err := parseCents(priceStr)
	if err != nil {
		return err
	}
	amount, err := parseShares(amountStr)
	if err != nil {
		return err
	}
	return execute(maaHex, "place_split_limit_order", []any{book, price, amount},
		fmt.Sprintf("SPLIT %d pairs on order book %d: hold YES, sell NO @ %dc", amount, book, 100-price),
		fmt.Sprintf("%.2f USDC locked from the agent wallet", float64(amount)))
}

// cancel: cancel_order. The chain stores a buy at -price and a sell at +price,
// and cancel takes the stored price, so the kind decides the sign. A buy
// refunds its locked USDC, a sell returns the shares to holdings.
func cancel(maaHex, bookStr, side, kind, priceStr string) error {
	book, err := strconv.Atoi(bookStr)
	if err != nil {
		return fmt.Errorf("order book id: %w", err)
	}
	price, err := parseCents(priceStr)
	if err != nil {
		return err
	}
	outcome, err := parseSide(side)
	if err != nil {
		return err
	}
	switch strings.ToLower(kind) {
	case "buy":
		price = -price
	case "sell":
	default:
		return fmt.Errorf("kind must be buy or sell, got %q", kind)
	}
	return execute(maaHex, "cancel_order", []any{book, outcome, price},
		fmt.Sprintf("CANCEL %s %s @ %dc on order book %d", strings.ToUpper(kind), strings.ToUpper(side), abs(price), book),
		"locked funds or shares return to the agent wallet")
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// execute runs one allow-listed action as the agent wallet and waits for it
// to commit. Every trading command goes through here.
func execute(maaHex, action string, args []any, what, money string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	maaAddr, err := util.NewEthereumAddressFromString(strings.TrimSpace(maaHex))
	if err != nil {
		return fmt.Errorf("bad MAA address: %w", err)
	}
	c, priv, err := client(ctx)
	if err != nil {
		return err
	}
	agent, _ := agentAddress(priv)
	actions, err := c.LoadActions()
	if err != nil {
		return err
	}

	fmt.Printf("agent wallet : %s\n", maaAddr.Address())
	fmt.Printf("signing as   : %s (restricted)\n", agent)
	fmt.Printf("order        : %s\n", what)
	fmt.Printf("collateral   : %s\n\n", money)

	tx, err := actions.ExecuteAgentAction(ctx, types.MAAExecuteInput{
		MAAAddress: maaAddr.Bytes(),
		Namespace:  "main",
		Action:     action,
		Args:       args,
	})
	if err != nil {
		return fmt.Errorf("%s as MAA: %w", action, err)
	}
	fmt.Printf("tx: %s\nhttps://trufscan.io/tx/%s\nwaiting for inclusion...\n", tx, tx)
	h, err := kwilTypes.NewHashFromString(tx)
	if err != nil {
		return fmt.Errorf("parse tx hash: %w", err)
	}
	res, err := c.WaitForTx(ctx, h, 2*time.Second)
	if err != nil {
		return fmt.Errorf("wait for tx: %w", err)
	}
	if res.Result.Code != uint32(kwilTypes.CodeOk) {
		return fmt.Errorf("tx FAILED (code %d): %s", res.Result.Code, res.Result.Log)
	}
	fmt.Println("\nOK, committed.")
	return nil
}
