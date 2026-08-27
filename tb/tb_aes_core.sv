// aes_core testbench. Three tests:
//   1. the FIPS-197 known answer vector from vectors/fips197_kat.txt
//   2. every vector in vectors/random_1000.txt (key_load + encrypt each time)
//   3. key reuse - load one key and encrypt several blocks without reloading,
//      since that's the case the AXI wrapper actually cares about. the first
//      three lines of random_1000.txt share the all zero key (gen_vectors
//      writes the edge cases as key x plaintext), so I reuse those.
// Plus a cycle count check on the latency.
//
// gui: set tb_aes_core as sim top and Run Simulation. or from the repo root:
//   xvlog -sv rtl/sbox.sv rtl/subbytes.sv rtl/shiftrows.sv rtl/mixcolumns.sv
//              rtl/key_expand.sv rtl/aes_core.sv tb/tb_aes_core.sv
//   xelab tb_aes_core -s tb_aes_core_sim
//   xsim tb_aes_core_sim -R

`timescale 1ns / 1ps

module tb_aes_core;

    logic         clk = 0;
    logic         rst;
    logic         key_load, start;
    logic [127:0] key, plaintext, ciphertext;
    logic         key_ready, done, busy;

    int errors = 0, n = 0;

    aes_core dut (
        .clk        (clk),
        .rst        (rst),
        .key_load   (key_load),
        .start      (start),
        .key        (key),
        .plaintext  (plaintext),
        .ciphertext (ciphertext),
        .key_ready  (key_ready),
        .done       (done),
        .busy       (busy)
    );

    always #5 clk = ~clk;  // 100 MHz

    // opens a vector file, repo root path first then the bare name (cli runs
    // from the repo root, the gui copies vectors into the sim dir)
    function automatic int open_vec(input string name);
        int fd;
        fd = $fopen({"vectors/", name}, "r");
        if (fd == 0) fd = $fopen(name, "r");
        if (fd == 0) begin
            $display("FAIL: can't open %s", name);
            $finish;
        end
        return fd;
    endfunction

    task load_key(input logic [127:0] k);
        key <= k;
        @(posedge clk);
        key_load <= 1'b1;
        @(posedge clk);
        key_load <= 1'b0;
        // edge not level - key_ready is still high from the last key at this
        // point, it doesn't drop until the fsm samples key_load
        @(posedge key_ready);
        @(posedge clk);
    endtask

    task encrypt(input logic [127:0] pt, input logic [127:0] exp_ct);
        plaintext <= pt;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        @(posedge done);   // same deal, done is still high from the last block
        #1;
        if (ciphertext !== exp_ct) begin
            $display("FAIL: key=%032x pt=%032x -> %032x, expected %032x",
                     key, pt, ciphertext, exp_ct);
            errors++;
        end
        n++;
    endtask

    logic [127:0] vk, vpt, vct;
    logic [127:0] reuse_pt [0:2], reuse_ct [0:2];
    int fd, cycles, nline;

    initial begin
        key_load = 1'b0;
        start    = 1'b0;
        rst      = 1'b1;
        repeat (2) @(posedge clk);
        rst <= 1'b0;

        // 1. FIPS-197 known answer test
        fd = open_vec("fips197_kat.txt");
        if ($fscanf(fd, "%h %h %h", vk, vpt, vct) != 3) begin
            $display("FAIL: bad fips197_kat.txt");
            $finish;
        end
        $fclose(fd);
        load_key(vk);
        encrypt(vpt, vct);
        if (errors == 0)
            $display("PASS: FIPS-197 KAT, ct = %032x", ciphertext);

        // latency check. counting posedges from the one that samples start to
        // the one where done goes high. that's 10, not 11 - the round 0
        // addroundkey happens on the same edge that accepts start. back to
        // back blocks still land 11 cycles apart because start can't be
        // accepted until the cycle after done.
        plaintext <= vpt;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);        // start sampled here
        start  <= 1'b0;
        cycles  = 0;
        do begin
            @(posedge clk);
            #1;                // let done settle before looking at it
            cycles++;
        end while (!done);
        if (cycles != 10) begin
            $display("FAIL: start to done took %0d cycles, expected 10", cycles);
            errors++;
        end else begin
            $display("PASS: 10 cycles start to done (11 cycles per block)");
        end

        // 2. the random vectors, fresh key each time
        fd    = open_vec("random_1000.txt");
        nline = 0;
        while ($fscanf(fd, "%h %h %h", vk, vpt, vct) == 3) begin
            if (nline < 3) begin       // stash the first three for the reuse test
                reuse_pt[nline] = vpt;
                reuse_ct[nline] = vct;
            end
            nline++;
            load_key(vk);
            encrypt(vpt, vct);
        end
        $fclose(fd);
        $display("ran %0d vectors from random_1000.txt", nline);

        // 3. one key_load, several blocks - key_ready should stay up
        load_key(128'h0);              // the key those first three vectors share
        for (int i = 0; i < 3; i++) begin
            encrypt(reuse_pt[i], reuse_ct[i]);
            if (!key_ready) begin
                $display("FAIL: key_ready dropped after block %0d", i);
                errors++;
            end
        end

        if (errors == 0)
            $display("PASS: aes_core matches the model on all %0d blocks", n);
        else
            $display("FAIL: %0d mismatches out of %0d blocks", errors, n);
        $finish;
    end

endmodule
