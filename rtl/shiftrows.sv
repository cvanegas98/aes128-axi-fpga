// shiftrows step (FIPS-197 5.1.2). row r of the state rotates left by r.
// pure wiring, costs nothing in hardware.
//
// the state is column major (byte i has row = i%4, col = i/4), so
// out[r][c] = in[r][(c+r)%4] works out to flat index (i + 4*(i%4)) % 16,
// same formula as shift_rows in the python model.

`timescale 1ns / 1ps

module shiftrows (
    input  logic [127:0] state_in,
    output logic [127:0] state_out
);

    generate
        for (genvar i = 0; i < 16; i++) begin : g_shift
            localparam int SRC = (i + 4 * (i % 4)) % 16;
            assign state_out[127 - 8*i -: 8] = state_in[127 - 8*SRC -: 8];
        end
    endgenerate

endmodule
