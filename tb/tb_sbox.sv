// sbox testbench. Exhaustive - runs all 256 inputs and compares against
// vectors/sbox.txt which comes from the python model (gen_vectors.py).
//
// two ways to run it:
// 1) vivado gui: source vivado/create_project.tcl in the tcl console once,
//    then open the project and hit Run Simulation. result prints in the
//    tcl console.
// 2) command line from the repo root:
//      xvlog -sv rtl/sbox.sv tb/tb_sbox.sv
//      xelab tb_sbox -s tb_sbox_sim
//      xsim tb_sbox_sim -R

`timescale 1ns / 1ps

module tb_sbox;

    logic [7:0] in_byte;
    logic [7:0] out_byte;
    logic [7:0] expected [0:255];
    int errors = 0;
    int fd;

    sbox dut (
        .in_byte  (in_byte),
        .out_byte (out_byte)
    );

    initial begin
        // the cli flow runs from the repo root, but the vivado gui sim runs
        // in its own directory and copies sbox.txt there (it's in the sim
        // fileset), so check which path exists
        fd = $fopen("vectors/sbox.txt", "r");
        if (fd != 0) begin
            $fclose(fd);
            $readmemh("vectors/sbox.txt", expected);
        end else begin
            $readmemh("sbox.txt", expected);
        end

        for (int i = 0; i < 256; i++) begin
            in_byte = i[7:0];
            #1;
            if (out_byte !== expected[i]) begin
                $display("FAIL: sbox(%02x) = %02x, expected %02x", i[7:0], out_byte, expected[i]);
                errors++;
            end
        end

        if (errors == 0)
            $display("PASS: all 256 sbox entries match the model");
        else
            $display("FAIL: %0d mismatches", errors);
        $finish;
    end

endmodule
