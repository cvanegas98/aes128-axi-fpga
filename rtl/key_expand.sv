// AES-128 key expansion (FIPS-197 section 5.2).
//
// Precomputes all 11 round keys up front instead of expanding on the fly
// each round - burns ~1400 FFs but the AXI use case is "write the key once,
// encrypt lots of blocks", so key expansion only happens on a key change and
// the encrypt datapath just indexes into the array.
//
// pulse start with the key held valid -> 10 cycles later done goes high and
// round_keys[0..10] are ready. done stays high until the next start/reset.
//
// each cycle computes one round key from the previous one:
//   w4i   = w4(i-1) ^ (subword(rotword(w4i-1)) ^ rcon)
//   w4i+1 = w4(i-1)+1 ^ w4i     ... and so on (words chain)

`timescale 1ns / 1ps

module key_expand (
    input  logic               clk,
    input  logic               rst,
    input  logic               start,
    input  logic [127:0]       key,
    output logic [10:0][127:0] round_keys,
    output logic               done
);

    // rcon[i] for rounds 1-10 (index 0 unused)
    localparam logic [7:0] RCON [0:10] =
        '{8'h00, 8'h01, 8'h02, 8'h04, 8'h08, 8'h10, 8'h20, 8'h40, 8'h80, 8'h1b, 8'h36};

    logic [3:0] rnd;   // round key currently being computed (1..10)
    logic       busy;

    // previous round key split into words (w[0] is the MSB word like FIPS-197)
    logic [127:0] prev;
    logic [31:0]  pw0, pw1, pw2, pw3;
    assign prev = round_keys[rnd - 1];
    assign {pw0, pw1, pw2, pw3} = prev;

    // rotword then subword on the last word
    logic [31:0] rot, sub;
    assign rot = {pw3[23:0], pw3[31:24]};

    sbox sb0 (.in_byte(rot[31:24]), .out_byte(sub[31:24]));
    sbox sb1 (.in_byte(rot[23:16]), .out_byte(sub[23:16]));
    sbox sb2 (.in_byte(rot[15:8]),  .out_byte(sub[15:8]));
    sbox sb3 (.in_byte(rot[7:0]),   .out_byte(sub[7:0]));

    // words of the next round key chain off each other
    logic [31:0] nw0, nw1, nw2, nw3;
    assign nw0 = pw0 ^ (sub ^ {RCON[rnd], 24'h0});
    assign nw1 = pw1 ^ nw0;
    assign nw2 = pw2 ^ nw1;
    assign nw3 = pw3 ^ nw2;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            rnd  <= 4'd0;
        end else if (start) begin
            round_keys[0] <= key;   // round key 0 is just the cipher key
            rnd  <= 4'd1;
            busy <= 1'b1;
            done <= 1'b0;
        end else if (busy) begin
            round_keys[rnd] <= {nw0, nw1, nw2, nw3};
            if (rnd == 4'd10) begin
                busy <= 1'b0;
                done <= 1'b1;
            end else begin
                rnd <= rnd + 4'd1;
            end
        end
    end

endmodule
