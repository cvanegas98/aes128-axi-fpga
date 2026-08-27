// subbytes step (FIPS-197 5.1.1). just 16 sboxes in parallel, one per state
// byte. pure combinational.
//
// byte numbering matches the python model: byte i of the block is
// state[127-8*i -: 8], so byte 0 is the MSB end (same as how key_expand
// treats the key).

`timescale 1ns / 1ps

module subbytes (
    input  logic [127:0] state_in,
    output logic [127:0] state_out
);

    generate
        for (genvar i = 0; i < 16; i++) begin : g_sbox
            sbox sb (
                .in_byte  (state_in[127 - 8*i -: 8]),
                .out_byte (state_out[127 - 8*i -: 8])
            );
        end
    endgenerate

endmodule
