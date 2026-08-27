// mixcolumns step (FIPS-197 5.1.3). each column gets multiplied by the
// fixed matrix [2 3 1 1; 1 2 3 1; 1 1 2 3; 3 1 1 2] over GF(2^8).
// pure combinational - a column is just xtimes and xors.
//
// xtime is multiply-by-2: shift left, and if the bit fell off the top,
// xor with 0x1b (the AES polynomial minus the x^8 term).
// 3*a = xtime(a) ^ a, so every matrix row is 2 xtimes + xors.

`timescale 1ns / 1ps

module mixcolumns (
    input  logic [127:0] state_in,
    output logic [127:0] state_out
);

    function automatic logic [7:0] xtime(input logic [7:0] b);
        return (b << 1) ^ (b[7] ? 8'h1b : 8'h00);
    endfunction

    generate
        for (genvar c = 0; c < 4; c++) begin : g_col
            logic [7:0] a0, a1, a2, a3;
            assign {a0, a1, a2, a3} = state_in[127 - 32*c -: 32];
            assign state_out[127 - 32*c -: 32] = {
                xtime(a0) ^ xtime(a1) ^ a1 ^ a2 ^ a3,   // 2 3 1 1
                a0 ^ xtime(a1) ^ xtime(a2) ^ a2 ^ a3,   // 1 2 3 1
                a0 ^ a1 ^ xtime(a2) ^ xtime(a3) ^ a3,   // 1 1 2 3
                xtime(a0) ^ a0 ^ a1 ^ a2 ^ xtime(a3)    // 3 1 1 2
            };
        end
    endgenerate

endmodule
