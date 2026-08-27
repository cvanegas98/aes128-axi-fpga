// AES-128 encrypt core - FSM + top level for the datapath.
//
// Iterative: one round per clock, so a block takes 11 cycles (1 for the
// initial addroundkey + 10 rounds). Round keys are precomputed by
// key_expand, not generated on the fly.
//
// Two separate pulses instead of one big start:
//   key_load - expand this key (11 cycles), key_ready goes high when done
//   start    - encrypt plaintext with the key already loaded (11 cycles),
//              done goes high and ciphertext is valid
// key_expand costs the same as a whole encryption, so making every block
// re-expand the key would double the work for the "load the key once,
// stream a bunch of blocks" case the AXI wrapper is going to want.
//
// start is ignored unless key_ready is high and the core is idle.
// done stays high until the next start (same convention as key_expand).
//
// the round is subbytes -> shiftrows -> mixcolumns -> addroundkey, except
// round 10 skips mixcolumns (FIPS-197 5.1). addroundkey is just an xor so
// it lives here instead of getting its own module.

`timescale 1ns / 1ps

module aes_core (
    input  logic         clk,
    input  logic         rst,
    input  logic         key_load,
    input  logic         start,
    input  logic [127:0] key,
    input  logic [127:0] plaintext,
    output logic [127:0] ciphertext,
    output logic         key_ready,
    output logic         done,
    output logic         busy
);

    typedef enum logic [1:0] {S_IDLE, S_EXPAND, S_ROUND} state_e;
    state_e cs;

    logic [3:0]         rnd;         // which round key we're xoring in (1..10)
    logic [127:0]       state_reg;   // the AES state between rounds

    // key expansion
    logic [10:0][127:0] round_keys;
    logic               ke_start, ke_done;

    // pulse key_expand's start straight from key_load so its done clears in
    // the same cycle we leave S_IDLE - otherwise the fsm would look at a
    // stale ke_done left over from the previous expansion
    assign ke_start = (cs == S_IDLE) && key_load;

    key_expand u_key_expand (
        .clk        (clk),
        .rst        (rst),
        .start      (ke_start),
        .key        (key),
        .round_keys (round_keys),
        .done       (ke_done)
    );

    // round datapath - one copy of each step, reused every cycle
    logic [127:0] sb_out, sr_out, mc_out, round_out;

    subbytes   u_subbytes   (.state_in (state_reg), .state_out (sb_out));
    shiftrows  u_shiftrows  (.state_in (sb_out),    .state_out (sr_out));
    mixcolumns u_mixcolumns (.state_in (sr_out),    .state_out (mc_out));

    // last round has no mixcolumns
    assign round_out = ((rnd == 4'd10) ? sr_out : mc_out) ^ round_keys[rnd];

    assign ciphertext = state_reg;
    assign busy       = (cs != S_IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            cs        <= S_IDLE;
            rnd       <= 4'd0;
            key_ready <= 1'b0;
            done      <= 1'b0;
        end else begin
            case (cs)
                S_IDLE: begin
                    if (key_load) begin
                        key_ready <= 1'b0;   // old round keys are stale now
                        cs        <= S_EXPAND;
                    end else if (start && key_ready) begin
                        state_reg <= plaintext ^ round_keys[0];  // addroundkey, round 0
                        rnd       <= 4'd1;
                        done      <= 1'b0;
                        cs        <= S_ROUND;
                    end
                end

                S_EXPAND: begin
                    if (ke_done) begin
                        key_ready <= 1'b1;
                        cs        <= S_IDLE;
                    end
                end

                S_ROUND: begin
                    state_reg <= round_out;
                    if (rnd == 4'd10) begin
                        done <= 1'b1;        // state_reg gets the ciphertext this same edge
                        cs   <= S_IDLE;
                    end else begin
                        rnd <= rnd + 4'd1;
                    end
                end

                default: cs <= S_IDLE;
            endcase
        end
    end

endmodule
