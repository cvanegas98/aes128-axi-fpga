// key_expand testbench. Runs the FIPS-197 Appendix A key and checks all 11
// round keys against vectors/fips197_roundkeys.txt from the python model.
// Also runs a second expansion back to back to make sure start reuses fine.
// The second run uses a different key (appendix c.1, vectors/roundkeys2.txt)
// - when both runs shared a key, a restart that quietly kept the old round
// keys still passed.
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
        // edge not level - done is still high from the previous run, so
        // wait(done) fell straight through and "checked" the old keys.
        // a posedge can only fire after done actually dropped and came back.
        @(posedge done);
        @(posedge clk);
        for (int i = 0; i <= 10; i++) begin
            if (round_keys[i] !== expected[i]) begin
                $display("FAIL: rk[%0d] = %032x, expected %032x", i, round_keys[i], expected[i]);
                errors++;
            end
        end
    endtask

    // same file fallback as tb_sbox (cli runs from repo root, gui copies
    // the file into the sim dir)
    // note: xsim garbles a {"a","b"} concat passed straight into $readmemh
    // from a static task ("File @@FP cannot be opened"), so build the path
    // in a string variable first and keep the task automatic
    task automatic load_expected(input string name);
        int f;
        string path;
        path = {"vectors/", name};
        f = $fopen(path, "r");
        if (f != 0) begin
            $fclose(f);
            $readmemh(path, expected);
        end else begin
            $readmemh(name, expected);
        end
    endtask

    // watchdog - a hang used to just spin forever, which in a scripted run
    // looks the same as still working. $finish not $fatal - xsim treats
    // $fatal like a breakpoint in -R mode and sits at the prompt, which
    // would be a hang inside the anti-hang mechanism
    initial begin
        #2ms;
        $display("FAIL: watchdog timeout, something hung");
        $finish;
    end

    initial begin
        start = 1'b0;
        rst   = 1'b1;
        repeat (2) @(posedge clk);
        rst <= 1'b0;

        // run 1: the appendix a key
        load_expected("fips197_roundkeys.txt");
        key = 128'h2b7e151628aed2a6abf7158809cf4f3c;
        run_and_check;

        // run 2: different key, so stale round keys can't pass by luck
        load_expected("roundkeys2.txt");
        key = 128'h000102030405060708090a0b0c0d0e0f;
        run_and_check;

        if (errors == 0)
            $display("PASS: all 11 round keys match on both keys");
        else
            $display("FAIL: %0d mismatches", errors);
        $finish;
    end

endmodule
