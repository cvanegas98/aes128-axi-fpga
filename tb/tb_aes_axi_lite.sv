// aes_axi_lite testbench. Hand rolled AXI4-Lite BFM rather than the Vivado
// AXI VIP - the VIP drags an IP dependency into the project and this bus is
// small enough that writing the handshakes myself is a better exercise
// anyway. If I have time later I'd like to run the VIP against it too as a
// cross check.
//
// The crypto is already covered by tb_aes_core (all 1000 vectors), so this tb
// is mostly about the wrapper: register readback, byte enables, the ctrl
// pulse bits, the ignore rules, and the irq. It runs a smaller batch of
// vectors through the bus just to prove the plumbing end to end.
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

    logic [127:0] vk, vpt, vct;
    logic [127:0] reuse_pt [0:2], reuse_ct [0:2];
    logic [31:0]  d;
    int fd, nline;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr  = 0; wdata  = 0; wstrb  = 4'hf; araddr = 0;
        aresetn = 0;
        repeat (4) @(posedge clk);
        aresetn <= 1'b1;
        repeat (2) @(posedge clk);

        // 1. everything should come out of reset zeroed
        check_reg(R_CTRL,   32'h0, "CTRL at reset");
        check_reg(R_STATUS, 32'h0, "STATUS at reset");
        check_reg(R_KEY0,   32'h0, "KEY0 at reset");
        check_reg(R_DIN0,   32'h0, "DIN0 at reset");

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
        //    this has to be done with a key already loaded, otherwise START
        //    is gated off by KEY_READY anyway and the test passes no matter
        //    which bit the wrapper prioritizes (found that the hard way by
        //    swapping the priority in a scratch copy and watching it still
        //    pass). with KEY_READY up, the wrong priority runs an encryption
        //    and DONE goes high, which is what we're checking for.
        write_key(128'h2b7e151628aed2a6abf7158809cf4f3c);
        axi_write(R_CTRL, 32'h1);
        poll_status(ST_KEY_READY);
        axi_write(R_CTRL, 32'h3);
        repeat (40) @(posedge clk);      // longer than an expand or an encrypt
        axi_read(R_STATUS, d);
        if (d[ST_DONE] !== 1'b0) begin
            $display("FAIL: START ran when KEY_LOAD was set too, DONE came up");
            errors++;
        end else if (d[ST_KEY_READY] !== 1'b1) begin
            $display("FAIL: KEY_LOAD didn't re-expand, KEY_READY never came back");
            errors++;
        end else begin
            $display("PASS: KEY_LOAD wins when both ctrl bits are set");
        end

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

        // 7. read only and unmapped addresses
        axi_write(R_STATUS, 32'hffffffff);       // should be swallowed
        axi_read(R_STATUS, d);
        if (d[31:3] !== 29'h0) begin
            $display("FAIL: STATUS took a write, reads %08x", d);
            errors++;
        end
        axi_write(R_DOUT0, 32'hffffffff);        // read only, also swallowed
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

        if (errors == 0)
            $display("PASS: aes_axi_lite, %0d blocks through the bus", n);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
