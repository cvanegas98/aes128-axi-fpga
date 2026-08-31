# Register map

The AXI4-Lite slave wrapper around aes_core. Writing this down before the RTL
so I'm not making it up as I go.

32-bit data bus, byte addressed, 64 byte aperture (so addr[5:2] picks the
register). Everything unused reads back 0. Writes to read only registers are
accepted and ignored. A slave is allowed to answer SLVERR there - I chose
OKAY-and-drop instead, since software is expected to poll STATUS and one
response path is less to get wrong.

Only addr[5:2] is decoded; anything above bit 5 is ignored because the
interconnect has already picked the window. If the wrapper is instantiated
with ADDR_WIDTH > 6 the map aliases every 64 bytes (0x40 is CTRL again).

AWPROT/ARPROT are present because AXI4-Lite requires them, and are ignored -
there's no privileged or secure distinction in this core.

| offset | name    | access | what it does           |
|--------|---------|--------|------------------------|
| 0x00   | CTRL    | rw     | kick off key expand / encrypt |
| 0x04   | STATUS  | ro     | key ready, busy, done  |
| 0x08   | KEY0    | rw     | key[127:96]            |
| 0x0C   | KEY1    | rw     | key[95:64]             |
| 0x10   | KEY2    | rw     | key[63:32]             |
| 0x14   | KEY3    | rw     | key[31:0]              |
| 0x18   | DIN0    | rw     | plaintext[127:96]      |
| 0x1C   | DIN1    | rw     | plaintext[95:64]       |
| 0x20   | DIN2    | rw     | plaintext[63:32]       |
| 0x24   | DIN3    | rw     | plaintext[31:0]        |
| 0x28   | DOUT0   | ro     | ciphertext[127:96]     |
| 0x2C   | DOUT1   | ro     | ciphertext[95:64]      |
| 0x30   | DOUT2   | ro     | ciphertext[63:32]      |
| 0x34   | DOUT3   | ro     | ciphertext[31:0]       |

## CTRL (0x00)

| bit  | name     | access | what it does |
|------|----------|--------|--------------|
| 0    | KEY_LOAD | w1p    | expand the key currently in KEY0-3 |
| 1    | START    | w1p    | encrypt DIN0-3 with the loaded key |
| 2    | IRQ_EN   | rw     | let DONE drive the irq output |
| 31:3 | -        | ro     | reads 0 |

w1p means write 1 to pulse: the wrapper turns the write into a one cycle
pulse on aes_core's key_load / start and the bit reads back 0. Writing 0 does
nothing. I did it this way so software doesn't have to write the bit high and
then low again, which would be two AXI transactions and a race with done.

KEY_LOAD and START are both ignored while BUSY is high. START is also ignored
unless KEY_READY is high, since aes_core would just sit there. Nothing errors
out, the write is dropped - software is supposed to poll STATUS first.

If both bits are set in the same write, KEY_LOAD wins and START is dropped
(aes_core can't do both at once and key expansion is the one that has to
happen first anyway).

## STATUS (0x04)

| bit  | name      | access | what it does |
|------|-----------|--------|--------------|
| 0    | KEY_READY | ro     | round keys are expanded and valid |
| 1    | BUSY      | ro     | core is expanding or encrypting |
| 2    | DONE      | ro     | ciphertext in DOUT0-3 is valid |
| 31:3 | -         | ro     | reads 0 |

These are just aes_core's key_ready / busy / done brought out. DONE stays high
until the next START, same as the core, so software can poll it and then read
DOUT whenever it gets around to it. KEY_READY drops on KEY_LOAD and comes back
when the expansion finishes.

## DOUT (0x28-0x34)

DOUT is a holding register, not a live view of the core. aes_core drives its
ciphertext output straight off the state register, so the wrapper captures it
on the DONE edge instead of wiring it through. That means:

- before the first block finishes, DOUT reads 0 (not the X the raw state
  register would give in sim)
- during an encryption DOUT still holds the *previous* ciphertext, so a read
  that lands mid block gets a real earlier result rather than a half
  encrypted state
- DOUT is valid as soon as STATUS.DONE reads back set. The capture happens
  one cycle after the core's internal done, and a STATUS read can't get back
  to software in under about three cycles, so software can't outrun it.

Torn reads are still possible and software has to avoid them: DOUT0-3 are
four separate transactions, and if a block completes partway through that
sequence the four words come from two different blocks. My own testbench hit
this by accident - four back to back reads take ~14 cycles and a block only
takes 11. Read DOUT only after DONE and before starting the next block.

## Interrupt

irq is level high, `DONE & IRQ_EN`. Since DONE is cleared by the next START,
software clears the interrupt by starting the next block, or by clearing
IRQ_EN if it's done. No separate write-1-to-clear status register - felt like
overkill for a core with one interrupt source.

## Word order

KEY0 is the *first* four bytes of the key as you'd write it in hex, i.e. for
the FIPS-197 Appendix A key 2b7e1516 28aed2a6 abf71588 09cf4f3c:

    KEY0 = 0x2b7e1516
    KEY1 = 0x28aed2a6
    KEY2 = 0xabf71588
    KEY3 = 0x09cf4f3c

so `{KEY0, KEY1, KEY2, KEY3}` is the 128 bit value aes_core wants. Same for
DIN and DOUT. This is the same MSB-first convention the python model and the
rest of the RTL use, so a hex string from the vector files drops straight in
without any byte swapping. Worth being explicit about because AXI is little
endian and it would be easy to end up mirrored.

## How software drives it

    write KEY0-3
    write CTRL.KEY_LOAD
    poll STATUS until KEY_READY
    for each block:
        write DIN0-3
        write CTRL.START
        poll STATUS until DONE   (or wait for the irq)
        read DOUT0-3

The key only gets expanded once. That's the whole reason aes_core has separate
key_load and start.
