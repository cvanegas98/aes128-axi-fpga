// aes_axi_lite testbench. Hand rolled AXI4-Lite BFM rather than the Vivado
// AXI VIP - the VIP drags an IP dependency into the project and this bus is
// small enough that writing the handshakes myself is a better exercise
// anyway. If I have time later I'd like to run the VIP against it too as a
// cross check.
//
// The crypto is already covered by tb_aes_core (all 1000 vectors), so this tb
// is mostly about the wrapper: register readback, byte enables, the ctrl
// pulse bits, the ignore rules (including writes landing while busy), and
// the irq. It runs a smaller batch of vectors through the bus just to prove
// the plumbing end to end.
//
// One BFM detail worth remembering: awready/wready/arready are combinational
// off *valid, so the handshake has to be sampled with the values that were
// on the bus going into the clock edge. That means reading them right after
// @(posedge clk) with no delay - adding a #1 would see the post-edge state
// and miss the handshake entirely.
//
// gui: set tb_aes_axi_lite as sim top, Run All (not Run Simulation, the
// default 1000ns isn't enough). or from the repo root:
//   xvlog -sv rtl/sbox.sv rtl/subbytes.sv rtl/shiftrows.sv rtl/mixcolumns.sv
//              rtl/key_expand.sv rtl/aes_core.sv rtl/axi/aes_axi_lite.sv
//              tb/tb_aes_axi_lite.sv
//   xelab tb_aes_axi_lite -s tb_aes_axi_lite_sim
//   xsim tb_aes_axi_lite_sim -R

`timescale 1ns / 1ps

module tb_aes_axi_lite;

    localparam int N_RANDOM = 100;   // bump this if I want a longer soak

    // register offsets, same as docs/register_map.md
    localparam logic [5:0] R_CTRL   = 6'h00;
    localparam logic [5:0] R_STATUS = 6'h04;
    localparam logic [5:0] R_KEY0   = 6'h08;
    localparam logic [5:0] R_DIN0   = 6'h18;
    localparam logic [5:0] R_DOUT0  = 6'h28;

    localparam int ST_KEY_READY = 0;
    localparam int ST_BUSY      = 1;
    localparam int ST_DONE      = 2;

    logic        clk = 0;
    logic        aresetn;

    logic [5:0]  awaddr;
    logic [2:0]  awprot, arprot;
    logic        awvalid, awready;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wvalid, wready;
    logic [1:0]  bresp;
    logic        bvalid, bready;
    logic [5:0]  araddr;
    logic        arvalid, arready;
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid, rready;
    logic        irq;

    int errors = 0, n = 0;

    aes_axi_lite dut (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (aresetn),
        .s_axi_awaddr  (awaddr),
        .s_axi_awprot  (awprot),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata   (wdata),
        .s_axi_wstrb   (wstrb),
        .s_axi_wvalid  (wvalid),
        .s_axi_wready  (wready),
        .s_axi_bresp   (bresp),
        .s_axi_bvalid  (bvalid),
        .s_axi_bready  (bready),
        .s_axi_araddr  (araddr),
        .s_axi_arprot  (arprot),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata   (rdata),
        .s_axi_rresp   (rresp),
        .s_axi_rvalid  (rvalid),
        .s_axi_rready  (rready),
        .irq           (irq)
    );

    always #5 clk = ~clk;  // 100 MHz

    // ---- BFM ----

    task automatic axi_write(input logic [5:0] addr,
                             input logic [31:0] data,
                             input logic [3:0]  strb = 4'hf);
        @(posedge clk);
        awaddr  <= addr;
        awprot  <= 3'b010;   // nonsecure data access - value is ignored, but
                             // drive something non-zero so a wrapper that
                             // accidentally decoded it would misbehave
        awvalid <= 1'b1;
        wdata   <= data;
        wstrb   <= strb;
        wvalid  <= 1'b1;
        bready  <= 1'b1;
        forever begin
            @(posedge clk);
            if (awready && wready) break;   // no delay here, see the note up top
        end
        awvalid <= 1'b0;
        wvalid  <= 1'b0;
        forever begin
            @(posedge clk);
            if (bvalid) break;
        end
        if (bresp !== 2'b00) begin
            $display("FAIL: write to 0x%02x got bresp %b", addr, bresp);
            errors++;
        end
        bready <= 1'b0;
    endtask

    task automatic axi_read(input logic [5:0] addr, output logic [31:0] data);
        @(posedge clk);
        araddr  <= addr;
        arprot  <= 3'b010;
        arvalid <= 1'b1;
        rready  <= 1'b1;
        forever begin
            @(posedge clk);
            if (arready) break;
        end
        arvalid <= 1'b0;
        forever begin
            @(posedge clk);
            if (rvalid) begin
                data = rdata;
                break;
            end
        end
        if (rresp !== 2'b00) begin
            $display("FAIL: read from 0x%02x got rresp %b", addr, rresp);
            errors++;
        end
        rready <= 1'b0;
    endtask

    task automatic check_reg(input logic [5:0] addr,
                             input logic [31:0] exp,
                             input string what);
        logic [31:0] got;
        axi_read(addr, got);
        if (got !== exp) begin
            $display("FAIL: %s (0x%02x) = %08x, expected %08x", what, addr, got, exp);
            errors++;
        end
    endtask

    // ---- helpers that speak the register map ----

    task automatic write_key(input logic [127:0] k);
        for (int i = 0; i < 4; i++)
            axi_write(R_KEY0 + 6'(4*i), k[127 - 32*i -: 32]);
    endtask

    task automatic write_din(input logic [127:0] pt);
        for (int i = 0; i < 4; i++)
            axi_write(R_DIN0 + 6'(4*i), pt[127 - 32*i -: 32]);
    endtask

    task automatic read_dout(output logic [127:0] ct);
        logic [31:0] w;
        for (int i = 0; i < 4; i++) begin
            axi_read(R_DOUT0 + 6'(4*i), w);
            ct[127 - 32*i -: 32] = w;
        end
    endtask

    task automatic poll_status(input int bitnum);
        logic [31:0] s;
        forever begin
            axi_read(R_STATUS, s);
            if (s[bitnum]) break;
        end
    endtask

    task automatic load_key(input logic [127:0] k);
        write_key(k);
        axi_write(R_CTRL, 32'h1);        // KEY_LOAD
        poll_status(ST_KEY_READY);
    endtask

    task automatic encrypt(input logic [127:0] pt, input logic [127:0] exp_ct);
        logic [127:0] ct;
        write_din(pt);
        axi_write(R_CTRL, 32'h2);        // START
        poll_status(ST_DONE);
        read_dout(ct);
        if (ct !== exp_ct) begin
            $display("FAIL: pt=%032x -> %032x, expected %032x", pt, ct, exp_ct);
            errors++;
        end
        n++;
    endtask

    // ---- vector file ----

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

    logic [127:0] vk, vpt, vct, rb;
    logic [127:0] reuse_pt [0:2], reuse_ct [0:2];
    logic [31:0]  d;
    int fd, nline, e0;

    // watchdog - a hang (dead handshake, done that never comes) used to just
    // spin forever, which in a scripted run looks the same as still working
    initial begin
        #2ms;
        $display("FAIL: watchdog timeout, something hung");
        $finish;   // not $fatal - xsim -R stops at a prompt on $fatal
    end

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr  = 0; wdata  = 0; wstrb  = 4'hf; araddr = 0;
        awprot  = 0; arprot = 0;
        aresetn = 0;
        repeat (4) @(posedge clk);
        aresetn <= 1'b1;
        repeat (2) @(posedge clk);

        // 1. everything should come out of reset zeroed. DOUT is in this list
        //    now - it used to be wired straight to the core's state register,
        //    so before the first block it read X and this check would have
        //    failed (which is why it wasn't here)
        check_reg(R_CTRL,   32'h0, "CTRL at reset");
        check_reg(R_STATUS, 32'h0, "STATUS at reset");
        check_reg(R_KEY0,   32'h0, "KEY0 at reset");
        check_reg(R_DIN0,   32'h0, "DIN0 at reset");
        read_dout(rb);
        if (rb !== 128'h0) begin
            $display("FAIL: DOUT at reset = %032x, expected 0", rb);
            errors++;
        end

        // 2. plain register readback
        axi_write(R_KEY0 + 6'h4, 32'hdeadbeef);
        check_reg(R_KEY0 + 6'h4, 32'hdeadbeef, "KEY1 readback");
        axi_write(R_DIN0 + 6'h8, 32'h01234567);
        check_reg(R_DIN0 + 6'h8, 32'h01234567, "DIN2 readback");

        // 3. byte enables - only the two low bytes should move
        axi_write(R_KEY0 + 6'h4, 32'hffffffff, 4'b0011);
        check_reg(R_KEY0 + 6'h4, 32'hdeadffff, "KEY1 after partial write");

        // 4. START before a key is loaded should be dropped on the floor
        axi_write(R_CTRL, 32'h2);
        repeat (4) @(posedge clk);
        check_reg(R_STATUS, 32'h0, "STATUS after START with no key");

        // 5. writing both KEY_LOAD and START at once - key_load has to win.
        //    take two on this test. take one waited and looked at the settled
        //    levels, but KEY_READY was still high from the load above, so
        //    "key_load won" and "the write did nothing at all" read identical
        //    afterwards - a mutation that dropped both bits passed. the tell
        //    is the transient: if key_load really fired, then right after the
        //    write the core is busy re-expanding with KEY_READY down. a read
        //    lands ~3 cycles after the write and the expansion takes 11, so
        //    the window is comfortably visible.
        write_key(128'h2b7e151628aed2a6abf7158809cf4f3c);
        axi_write(R_CTRL, 32'h1);
        poll_status(ST_KEY_READY);
        e0 = errors;
        axi_write(R_CTRL, 32'h3);
        axi_read(R_STATUS, d);           // lands inside the expansion window
        if (d[ST_BUSY] !== 1'b1 || d[ST_KEY_READY] !== 1'b0) begin
            $display("FAIL: CTRL=3 didn't kick off a re-expansion (busy=%b key_ready=%b)",
                     d[ST_BUSY], d[ST_KEY_READY]);
            errors++;
        end
        poll_status(ST_KEY_READY);       // let the expansion finish
        axi_read(R_STATUS, d);
        if (d[ST_DONE] !== 1'b0) begin
            $display("FAIL: START ran when KEY_LOAD was set too, DONE came up");
            errors++;
        end
        if (errors == e0)
            $display("PASS: KEY_LOAD wins when both ctrl bits are set");

        // 6. the FIPS-197 known answer vector, all the way through the bus
        fd = open_vec("fips197_kat.txt");
        if ($fscanf(fd, "%h %h %h", vk, vpt, vct) != 3) begin
            $display("FAIL: bad fips197_kat.txt");
            $finish;
        end
        $fclose(fd);
        load_key(vk);
        encrypt(vpt, vct);
        if (errors == 0)
            $display("PASS: FIPS-197 KAT over AXI");

        // 7. read only and unmapped addresses. bresp is hardwired OKAY, so
        //    just writing and checking the response proves nothing (a mutation
        //    that routed DOUT writes into the key regs passed take one of this
        //    test) - the write has to be shown to land *nowhere*, so read the
        //    likely victims back afterwards
        axi_write(R_STATUS, 32'hffffffff);       // should be swallowed
        axi_read(R_STATUS, d);
        if (d[31:3] !== 29'h0) begin
            $display("FAIL: STATUS took a write, reads %08x", d);
            errors++;
        end
        axi_write(R_DOUT0, 32'hffffffff);        // read only, also swallowed
        read_dout(rb);
        if (rb !== vct) begin
            $display("FAIL: DOUT changed after a write to it: %032x", rb);
            errors++;
        end
        check_reg(R_KEY0,        32'h2b7e1516, "KEY0 after RO writes");
        check_reg(R_KEY0 + 6'h4, 32'h28aed2a6, "KEY1 after RO writes");
        check_reg(R_KEY0 + 6'h8, 32'habf71588, "KEY2 after RO writes");
        check_reg(R_KEY0 + 6'hc, 32'h09cf4f3c, "KEY3 after RO writes");
        check_reg(6'h38, 32'h0, "unmapped 0x38");
        check_reg(6'h3c, 32'h0, "unmapped 0x3c");

        // 8. irq follows DONE once it's enabled
        if (irq !== 1'b0) begin
            $display("FAIL: irq high with IRQ_EN clear");
            errors++;
        end
        axi_write(R_CTRL, 32'h4);                // IRQ_EN
        check_reg(R_CTRL, 32'h4, "CTRL readback (pulse bits read 0)");
        #1;
        if (irq !== 1'b1) begin                  // DONE is still set from step 6
            $display("FAIL: irq didn't follow DONE");
            errors++;
        end
        axi_write(R_CTRL, 32'h0);                // clear IRQ_EN
        #1;
        if (irq !== 1'b0) begin
            $display("FAIL: irq stuck after clearing IRQ_EN");
            errors++;
        end else begin
            $display("PASS: irq tracks DONE & IRQ_EN");
        end

        // 9. a batch of real vectors through the bus
        fd    = open_vec("random_1000.txt");
        nline = 0;
        while (nline < N_RANDOM && $fscanf(fd, "%h %h %h", vk, vpt, vct) == 3) begin
            if (nline < 3) begin
                reuse_pt[nline] = vpt;
                reuse_ct[nline] = vct;
            end
            nline++;
            load_key(vk);
            encrypt(vpt, vct);
        end
        $fclose(fd);
        $display("ran %0d vectors over AXI", nline);

        // 10. one key load, several blocks - the case the wrapper exists for
        load_key(128'h0);
        for (int i = 0; i < 3; i++) begin
            encrypt(reuse_pt[i], reuse_ct[i]);
            axi_read(R_STATUS, d);
            if (!d[ST_KEY_READY]) begin
                $display("FAIL: KEY_READY dropped after block %0d", i);
                errors++;
            end
        end

        // 11. START while busy is dropped. the register map promises this and
        //     nothing tested it - no CTRL write ever landed while the core
        //     was running. kick off a block, hit START again mid encryption,
        //     and make sure exactly one block ran. (the wrapper's !busy gate
        //     and the core fsm enforce this identically, so this checks the
        //     contract, not which of the two layers did it.)
        e0 = errors;
        write_din(reuse_pt[0]);
        axi_write(R_CTRL, 32'h2);        // start the block
        axi_write(R_CTRL, 32'h2);        // lands a few cycles in - dropped
        axi_read(R_STATUS, d);
        if (d[ST_BUSY] !== 1'b1) begin
            $display("FAIL: expected to land in the busy window (STATUS=%08x)", d);
            errors++;
        end
        poll_status(ST_DONE);
        read_dout(rb);
        if (rb !== reuse_ct[0]) begin
            $display("FAIL: START while busy corrupted the block: %032x", rb);
            errors++;
        end
        // wait out a whole extra block time - if the second START had been
        // latched somewhere it would rerun and DONE would blink
        repeat (16) @(posedge clk);
        axi_read(R_STATUS, d);
        if (d[ST_DONE] !== 1'b1 || d[ST_BUSY] !== 1'b0) begin
            $display("FAIL: something ran after the dropped START (STATUS=%08x)", d);
            errors++;
        end
        if (errors == e0)
            $display("PASS: START while busy is dropped");

        // 12. KEY_LOAD while busy is dropped too - the key has to survive
        e0 = errors;
        write_din(reuse_pt[1]);
        axi_write(R_CTRL, 32'h2);
        axi_write(R_CTRL, 32'h1);        // key_load mid encryption - dropped
        poll_status(ST_DONE);
        read_dout(rb);
        if (rb !== reuse_ct[1]) begin
            $display("FAIL: KEY_LOAD while busy corrupted the block: %032x", rb);
            errors++;
        end
        axi_read(R_STATUS, d);
        if (d[ST_KEY_READY] !== 1'b1) begin
            $display("FAIL: KEY_LOAD while busy killed the loaded key");
            errors++;
        end
        encrypt(reuse_pt[2], reuse_ct[2]);   // and the key still works
        if (errors == e0)
            $display("PASS: KEY_LOAD while busy is dropped");

        // 13. DOUT holds the last finished block while a new one is running.
        //     ciphertext used to come straight off the core's state register,
        //     so a read landing mid encryption handed the bus a partially
        //     encrypted block. now it's captured on the done edge.
        e0 = errors;
        write_din(reuse_pt[0]);
        axi_write(R_CTRL, 32'h2);
        axi_read(R_STATUS, d);           // land inside the encryption
        if (d[ST_BUSY] !== 1'b1) begin
            $display("FAIL: expected to be mid encryption (STATUS=%08x)", d);
            errors++;
        end
        //  one word, not all four: a bus read is ~3-4 cycles and the block
        //  only takes 11, so read_dout() here would still be reading when the
        //  encryption finished and would splice the old and new ciphertexts
        //  together. that's the torn read hazard the register map warns about
        //  - worth knowing that it is easy to hit by accident. one word lands
        //  ~5 cycles before the capture, which is the margin this check wants.
        axi_read(R_DOUT0, d);
        if (d !== reuse_ct[2][127:96]) begin
            $display("FAIL: DOUT0 moved mid encryption: %08x (want the previous block %08x)",
                     d, reuse_ct[2][127:96]);
            errors++;
        end
        poll_status(ST_DONE);
        read_dout(rb);
        if (rb !== reuse_ct[0]) begin
            $display("FAIL: DOUT didn't update after done: %032x", rb);
            errors++;
        end
        if (errors == e0)
            $display("PASS: DOUT holds the last block, no mid round state on the bus");

        // 14. DOUT is valid as soon as DONE reads back set - the capture is a
        //     cycle behind the core's done, so check software can't outrun it
        e0 = errors;
        write_din(reuse_pt[1]);
        axi_write(R_CTRL, 32'h2);
        poll_status(ST_DONE);            // returns the instant DONE reads 1
        axi_read(R_DOUT0, d);            // very next transaction
        if (d !== reuse_ct[1][127:96]) begin
            $display("FAIL: DOUT0 stale right after DONE: %08x, expected %08x",
                     d, reuse_ct[1][127:96]);
            errors++;
        end
        if (errors == e0)
            $display("PASS: DOUT valid on the first read after DONE");

        // 15. reset while a response is pending. bvalid has to drop straight
        //     away, not linger until the next clock edge, and the wrapper has
        //     to come back usable afterwards
        e0 = errors;
        @(posedge clk);
        awaddr <= R_KEY0; wdata <= 32'hcafef00d; wstrb <= 4'hf;
        awvalid <= 1'b1; wvalid <= 1'b1; bready <= 1'b0;   // hold the response
        forever begin
            @(posedge clk);
            if (awready && wready) break;
        end
        awvalid <= 1'b0; wvalid <= 1'b0;
        forever begin
            @(posedge clk);
            if (bvalid) break;
        end
        aresetn <= 1'b0;                 // reset with BVALID still up
        #1;
        if (bvalid !== 1'b0) begin
            $display("FAIL: BVALID stayed high while ARESETN was low");
            errors++;
        end
        repeat (3) @(posedge clk);
        aresetn <= 1'b1;
        repeat (2) @(posedge clk);
        bready <= 1'b0;
        check_reg(R_KEY0,   32'h0, "KEY0 after reset");
        check_reg(R_STATUS, 32'h0, "STATUS after reset");
        if (errors == e0)
            $display("PASS: reset drops a pending response and clears the regs");

        // 16. reset in the middle of an encryption. the core has to come back
        //     idle rather than finishing the block or wedging
        e0 = errors;
        load_key(128'h0);
        write_din(reuse_pt[0]);
        axi_write(R_CTRL, 32'h2);
        axi_read(R_STATUS, d);
        if (d[ST_BUSY] !== 1'b1) begin
            $display("FAIL: expected busy before the mid encryption reset");
            errors++;
        end
        aresetn <= 1'b0;
        repeat (3) @(posedge clk);
        aresetn <= 1'b1;
        repeat (2) @(posedge clk);
        axi_read(R_STATUS, d);
        if (d !== 32'h0) begin
            $display("FAIL: STATUS after mid encryption reset = %08x, expected 0", d);
            errors++;
        end
        // and it still works afterwards
        load_key(128'h0);
        encrypt(reuse_pt[0], reuse_ct[0]);
        if (errors == e0)
            $display("PASS: reset mid encryption recovers");

        if (errors == 0)
            $display("PASS: aes_axi_lite, %0d blocks through the bus", n);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
