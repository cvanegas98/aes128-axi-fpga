// key_expand testbench. Runs the FIPS-197 Appendix A key and checks all 11
// round keys against vectors/fips197_roundkeys.txt from the python model.
// Also runs a second expansion back to back to make sure start reuses fine.
//
// gui: set tb_key_expand as the sim top (right click it under Simulation
// Sources) and Run Simulation. or from the repo root:
//   xvlog -sv rtl/sbox.sv rtl/key_expand.sv tb/tb_key_expand.sv
//   xelab tb_key_expand -s tb_key_expand_sim
//   xsim tb_key_expand_sim -R

`timescale 1ns / 1ps

module tb_key_expand;

    logic               clk = 0;
    logic               rst;
    logic               start;
    logic [127:0]       key;
    logic [10:0][127:0] round_keys;
    logic               done;

    logic [127:0] expected [0:10];
    int errors = 0;
    int fd;

    key_expand dut (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .key        (key),
        .round_keys (round_keys),
        .done       (done)
    );

    always #5 clk = ~clk;  // 100 MHz

    task run_and_check;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        wait (done);
        @(posedge clk);
        for (int i = 0; i <= 10; i++) begin
            if (round_keys[i] !== expected[i]) begin
                $display("FAIL: rk[%0d] = %032x, expected %032x", i, round_keys[i], expected[i]);
                errors++;
            end
        end
    endtask

    initial begin
        // same file fallback as tb_sbox (cli runs from repo root, gui copies
        // the file into the sim dir)
        fd = $fopen("vectors/fips197_roundkeys.txt", "r");
        if (fd != 0) begin
            $fclose(fd);
            $readmemh("vectors/fips197_roundkeys.txt", expected);
        end else begin
            $readmemh("fips197_roundkeys.txt", expected);
        end

        key   = 128'h2b7e151628aed2a6abf7158809cf4f3c;
        start = 1'b0;
        rst   = 1'b1;
        repeat (2) @(posedge clk);
        rst <= 1'b0;

        run_and_check;
        run_and_check;  // second run, same key - done should drop and come back

        if (errors == 0)
            $display("PASS: all 11 round keys match FIPS-197 Appendix A (x2 runs)");
        else
            $display("FAIL: %0d mismatches", errors);
        $finish;
    end

endmodule
