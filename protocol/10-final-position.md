# Pre-teardown snapshot, 2026-09-18 04:16 UTC

Local node removed at this point. Position settles 2026-09-18 20:15 UTC.
Outcome must be checked at predict.truflation.com or trufscan.io.

## Position
```
AGENT WALLET  0x1167edf0430a562b06a48e027a4be52c44305e0a
  free USDC              1.58

  book band             side kind        qty   mark    value           settles
------------------------------------------------------------------------------
  1176 2.55-2.62        YES  holding       9    34c     3.06   09-18 20:15 UTC

  positions (at bid)     3.06
  locked in bids         0.00
  free USDC              1.58
  EQUITY                 4.64

LEDGER (main.ob_net_impacts)
  spent        3.42
  received     0.00
  net         -3.42   (negative while capital is deployed)

IF EACH POSITION SETTLES IN THE MONEY
  book 1176: 9 shares -> $8.82 if it wins, $0.00 if not (marked $3.06)

Mark is the best OTHER-PARTY bid, which is what you could sell into now.
```

## Ladder state and settlement exposure
```
MARKET  CESR  (stdbed26b8f3354c386b5b5ac2589529)
        provider 0x1566e5dad82127d2193a504100ec16c17407f3da  stream_ref 257596
        settles 2026-09-18 20:15 UTC   in 16.0h   5 order books
        current 2.5897   daily move mu=-0.0009 sd=0.0414 over 89 moves

  book band                   P   bid   ask  buy edge  sell edge  size@ask
--------------------------------------------------------------------------
  1174 below 2.48          0.4%     8    12     -11.6       +7.6        29
  1175 2.48-2.55          17.0%    20    24      -7.0       +3.0        15
  1176 2.55-2.62          60.0%    34     -         -      -26.0         -
  1177 2.62-2.69          21.8%    20    24      -2.2       -1.8        15
  1178 above 2.69          0.7%     8    12     -11.3       +7.3        29

No positive-edge buy. The book is priced at or above model.

SETTLEMENT MECHANICS
  last 11 settled ladders on this stream:
      0 print was on chain first (resolved on the new print)
      0 print arrived after attestation (resolved on the PRIOR
        print, as designed: publication lag, not a bug)
     11 straddled the print (EXPOSED to a split: BUG #1430)
  split harm: 2 of 11 settled with a winner count other than 1
  current print 2.5897 sits in order book 1176 (2.55-2.62), asking no ask.
  This stream tends to publish after settle_time, so that is the value
  attestation is likely to capture. Modelling publication lag, not a bug.

CAVEATS. The move model assumes normality and constant variance from 89 observations. A maker quoting against you may hold intraday data that is not on chain. Size accordingly.
```
