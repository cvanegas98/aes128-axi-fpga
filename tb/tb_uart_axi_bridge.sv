// uart_axi_bridge testbench.
//
// This one drives the bridge at the BYTE level - rx_data/rx_valid straight
// in, tx_data/tx_send watched on the way out - with a stub standing in for
// uart_tx. The serial timing is already tb_uart_rx and tb_uart_tx's problem
// and tb_aes_uart_top runs the real thing; splitting them means a failure
// here is the command protocol or the AXI master and nothing else. It also
// runs in a couple of hundred microseconds instead of milliseconds.
//
// The stub is deliberately NOT uart_tx. Its busy length is a variable the
// tests change, including 0 (busy never really goes high) and long, because
// the handshake in the bridge assumes things about when busy rises and I
// want those assumptions poked by something that is not the module they were
// written against.
//
// What makes this a real test and not two of my own modules agreeing:
//  - the command byte streams are built here from the protocol as written
//    down in uart_axi_bridge.sv's header, not from anything the bridge does
//  - the expected ciphertexts come from vectors/random_1000.txt, which is
//    the python model, which was checked against pycryptodome and FIPS-197
//  - the AXI protocol assertions below are the same spec rules as in
//    tb_aes_axi_lite (IHI 0022 A3.2), except now they are watching a real
//    RTL master instead of my BFM. That is the cross check I wanted out of
//    building this thing.
//
// from the repo root:
//   xvlog -sv rtl/sbox.sv rtl/subbytes.sv rtl/shiftrows.sv rtl/mixcolumns.sv
//             rtl/key_expand.sv rtl/aes_core.sv rtl/axi/aes_axi_lite.sv
//             rtl/uart/uart_axi_bridge.sv tb/tb_uart_axi_bridge.sv
//   xelab tb_uart_axi_bridge -s tb_uart_axi_bridge_sim
//   xsim tb_uart_axi_bridge_sim -R

`timescale 1ns / 1ps

module tb_uart_axi_bridge;

    localparam int N_SOAK   = 20;   // vectors in the soak

    logic clk = 0;
    logic rst;

    // byte side
    logic [7:0] rx_data = 8'h0;
    logic       rx_valid = 1'b0;
    logic [7:0] tx_data;
    logic       tx_send;
    logic       tx_busy;

    // axi wires between the bridge and the wrapper
    logic [5:0]  awaddr, araddr;
    logic [2:0]  awprot, arprot;
    logic        awvalid, awready, arvalid, arready;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic        wvalid, wready;
    logic [1:0]  bresp, rresp;
    logic        bvalid, bready, rvalid, rready;

    logic [7:0] status_o;
    logic       overrun, resp_err, cmd_err;

    // slave side of the stall injector below. the bridge drives the plain
    // names, the wrapper sees the s_ ones, and the assertions all watch the
    // plain (master) side because the master is what is under test here.
    logic        s_awvalid, s_wvalid, s_arvalid;
    logic        s_awready, s_wready, s_arready;
    logic        s_bvalid, s_bready, s_rvalid, s_rready;

    int errors = 0, n = 0;

    always #5 clk = ~clk;   // 100 MHz

    uart_axi_bridge dut (
        .clk           (clk),
        .rst           (rst),
        .rx_data       (rx_data),
        .rx_valid      (rx_valid),
        .tx_data       (tx_data),
        .tx_send       (tx_send),
        .tx_busy       (tx_busy),
        .m_axi_awaddr  (awaddr),
        .m_axi_awprot  (awprot),
        .m_axi_awvalid (awvalid),
        .m_axi_awready (awready),
        .m_axi_wdata   (wdata),
        .m_axi_wstrb   (wstrb),
        .m_axi_wvalid  (wvalid),
        .m_axi_wready  (wready),
        .m_axi_bresp   (bresp),
        .m_axi_bvalid  (bvalid),
        .m_axi_bready  (bready),
        .m_axi_araddr  (araddr),
        .m_axi_arprot  (arprot),
        .m_axi_arvalid (arvalid),
        .m_axi_arready (arready),
        .m_axi_rdata   (rdata),
        .m_axi_rresp   (rresp),
        .m_axi_rvalid  (rvalid),
        .m_axi_rready  (rready),
        .status_o      (status_o),
        .overrun       (overrun),
        .resp_err      (resp_err),
        .cmd_err       (cmd_err)
    );

    aes_axi_lite slave (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (~rst),
        .s_axi_awaddr  (awaddr),
        .s_axi_awprot  (awprot),
        .s_axi_awvalid (s_awvalid),
        .s_axi_awready (s_awready),
        .s_axi_wdata   (wdata),
        .s_axi_wstrb   (wstrb),
        .s_axi_wvalid  (s_wvalid),
        .s_axi_wready  (s_wready),
        .s_axi_bresp   (bresp),
        .s_axi_bvalid  (s_bvalid),
        .s_axi_bready  (s_bready),
        .s_axi_araddr  (araddr),
        .s_axi_arprot  (arprot),
        .s_axi_arvalid (s_arvalid),
        .s_axi_arready (s_arready),
        .s_axi_rdata   (rdata),
        .s_axi_rresp   (rresp),
        .s_axi_rvalid  (s_rvalid),
        .s_axi_rready  (s_rready),
        .irq           ()
    );

    // 2ms, same as the other clocked tbs. a whole passing run is ~250us -
    // one 'E' is a few axi transactions plus 16 stub bytes, call it 3us, and
    // there are about 50 commands in here. I had this at 40us first and it
    // fired on a perfectly good run, which is its own little lesson about
    // watchdogs. $finish not $fatal: under xsim -R, $fatal stops at a prompt
    // like a breakpoint, so the anti-hang mechanism would itself hang.
    initial begin
        #2ms;
        $display("FAIL: watchdog timeout, something hung");
        $display("FAIL: %0d errors", errors + 1);
        $finish;
    end

    // ---- protocol checkers ----
    //
    // Straight out of IHI 0022 A3.2, same rules as tb_aes_axi_lite. There
    // they were mostly aimed at the slave with the master side thrown in to
    // police my BFM; here it is the other way round - the master is the new
    // thing under test and these are the only opinion in the room that did
    // not come from me writing both ends.

    a_awvalid_held: assert property (@(posedge clk) disable iff (rst)
        (awvalid && !awready) |=> awvalid && $stable(awaddr) && $stable(awprot))
        else begin $display("FAIL: bridge moved AW before AWREADY"); errors++; end

    a_wvalid_held: assert property (@(posedge clk) disable iff (rst)
        (wvalid && !wready) |=> wvalid && $stable(wdata) && $stable(wstrb))
        else begin $display("FAIL: bridge moved W before WREADY"); errors++; end

    a_arvalid_held: assert property (@(posedge clk) disable iff (rst)
        (arvalid && !arready) |=> arvalid && $stable(araddr) && $stable(arprot))
        else begin $display("FAIL: bridge moved AR before ARREADY"); errors++; end

    a_bvalid_held: assert property (@(posedge clk) disable iff (rst)
        (bvalid && !bready) |=> bvalid)
        else begin $display("FAIL: BVALID dropped before BREADY"); errors++; end

    a_rvalid_held: assert property (@(posedge clk) disable iff (rst)
        (rvalid && !rready) |=> rvalid && $stable(rdata) && $stable(rresp))
        else begin $display("FAIL: RVALID/RDATA moved before RREADY"); errors++; end

    // nothing on either side may drive a VALID during reset
    a_quiet_in_reset: assert property (@(posedge clk)
        rst |-> (!awvalid && !wvalid && !arvalid && !bvalid && !rvalid))
        else begin $display("FAIL: a channel was live during reset"); errors++; end

    // the master must not have more than one transaction in flight - this
    // bridge is single outstanding by construction and if that ever stopped
    // being true the ordering of my DOUT reads would stop being safe
    int wr_out = 0, rd_out = 0;
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_out <= 0;
            rd_out <= 0;
        end else begin
            wr_out <= wr_out + ((awvalid && awready) ? 1 : 0) - ((bvalid && bready) ? 1 : 0);
            rd_out <= rd_out + ((arvalid && arready) ? 1 : 0) - ((rvalid && rready) ? 1 : 0);
        end
    end

    a_single_outstanding: assert property (@(posedge clk) disable iff (rst)
        (wr_out <= 1) && (rd_out <= 1) && !(wr_out > 0 && rd_out > 0))
        else begin $display("FAIL: bridge had more than one transaction outstanding"); errors++; end

    a_no_orphan_b: assert property (@(posedge clk) disable iff (rst)
        bvalid |-> (wr_out > 0))
        else begin $display("FAIL: BVALID with no write outstanding"); errors++; end

    a_no_orphan_r: assert property (@(posedge clk) disable iff (rst)
        rvalid |-> (rd_out > 0))
        else begin $display("FAIL: RVALID with no read outstanding"); errors++; end

    // the bridge only ever asks for a full word, and only inside the map
    a_wstrb_full: assert property (@(posedge clk) disable iff (rst)
        wvalid |-> (wstrb == 4'hf))
        else begin $display("FAIL: bridge drove a partial wstrb"); errors++; end

    a_addr_aligned: assert property (@(posedge clk) disable iff (rst)
        (awvalid |-> awaddr[1:0] == 2'b00) and (arvalid |-> araddr[1:0] == 2'b00))
        else begin $display("FAIL: bridge drove an unaligned address"); errors++; end


    // ---- stall injector ----
    //
    // Mutation testing is what made me write this. aes_axi_lite drives
    // AWREADY/WREADY/ARREADY combinationally off the VALIDs, so it is ALWAYS
    // ready - which means the master's "hold VALID until READY" logic never
    // gets exercised in the direction that could fail. Breaking the bridge so
    // it drops AWVALID before AWREADY passed every test I had. The assertion
    // for it was right; there was just never a cycle where AWVALID was up and
    // AWREADY was not.
    //
    // So this sits between the two and holds each channel off for a few
    // cycles. It hides VALID from the slave rather than masking READY back at
    // the master: masking READY would let the slave believe a handshake
    // happened that the master never saw. Hiding VALID just makes the request
    // arrive later, which is legal on both sides - and once the count reaches
    // zero it stays there until the transfer completes, so VALID never drops
    // on the slave side either.
    //
    // stall_max = 0 is a straight pass through, so every directed test below
    // drives the bus exactly the way it did before I added this.

    int stall_max = 0;
    int aw_c = 0, w_c = 0, ar_c = 0, b_c = 0, r_c = 0;

    function automatic int pick_stall();
        return (stall_max == 0) ? 0 : $urandom_range(0, stall_max);
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            aw_c <= 0; w_c <= 0; ar_c <= 0; b_c <= 0; r_c <= 0;
        end else begin
            if (!awvalid)  aw_c <= pick_stall();  else if (aw_c > 0) aw_c <= aw_c - 1;
            if (!wvalid)   w_c  <= pick_stall();  else if (w_c  > 0) w_c  <= w_c  - 1;
            if (!arvalid)  ar_c <= pick_stall();  else if (ar_c > 0) ar_c <= ar_c - 1;
            if (!s_bvalid) b_c  <= pick_stall();  else if (b_c  > 0) b_c  <= b_c  - 1;
            if (!s_rvalid) r_c  <= pick_stall();  else if (r_c  > 0) r_c  <= r_c  - 1;
        end
    end

    // requests: hidden from the slave while the count runs
    assign s_awvalid = awvalid && (aw_c == 0);
    assign s_wvalid  = wvalid  && (w_c  == 0);
    assign s_arvalid = arvalid && (ar_c == 0);
    assign awready   = s_awready;   // 0 anyway while the request is hidden
    assign wready    = s_wready;
    assign arready   = s_arready;

    // responses: hidden from the master, and the master's READY is hidden
    // from the slave at the same time so the two never disagree about
    // whether a transfer happened
    assign bvalid   = s_bvalid && (b_c == 0);
    assign s_bready = bready   && (b_c == 0);
    assign rvalid   = s_rvalid && (r_c == 0);
    assign s_rready = rready   && (r_c == 0);

    // ---- uart_tx stub ----
    //
    // Holds busy for tx_busy_len cycles after send. Not uart_tx: if the
    // bridge only worked against the transmitter I wrote it alongside, that
    // is the same trap as the bfm agreeing with the slave. Every byte it is
    // handed gets logged so the tests can check what came out and in what
    // order.

    int  tx_busy_len = 12;
    int  tx_cnt = 0;
    bit  tx_active = 0;

    assign tx_busy = tx_active;

    // big enough for every byte the whole run produces. it was [0:255] first
    // and the soak walked off the end of it, which showed up as ciphertexts
    // full of X about two thirds of the way through - the check below turns
    // that into one clear message instead of nine confusing ones.
    localparam int SENT_MAX = 2048;
    logic [7:0] sent [0:SENT_MAX-1];
    int         sent_n = 0;

    // plain always, not always_ff - sent_n is also poked from the test
    // sequence and always_ff insists on a single driver
    always @(posedge clk) begin
        if (rst) begin
            tx_active <= 1'b0;
            tx_cnt    <= 0;
        end else begin
            if (tx_send) begin
                if (tx_active) begin
                    // the bridge is supposed to wait for busy to drop
                    $display("FAIL: send pulsed while the transmitter was busy, byte %02x lost",
                             tx_data);
                    errors++;
                end
                if (sent_n >= SENT_MAX) begin
                    $display("FAIL: tb ran out of room in sent[] at %0d bytes", sent_n);
                    errors++;
                    $finish;
                end
                sent[sent_n] = tx_data;
                sent_n++;
                if (tx_busy_len > 0) begin
                    tx_active <= 1'b1;
                    tx_cnt    <= tx_busy_len;
                end
            end else if (tx_active) begin
                if (tx_cnt <= 1) tx_active <= 1'b0;
                else             tx_cnt    <= tx_cnt - 1;
            end
        end
    end

    // ---- host side ----
    //
    // Builds the byte streams from the protocol as documented, not from
    // anything the bridge does.

    task automatic send_byte(input logic [7:0] b);
        @(posedge clk);
        rx_data  <= b;
        rx_valid <= 1'b1;
        @(posedge clk);
        rx_valid <= 1'b0;
        // the real uart hands over one byte per 10 bit times; a few idle
        // cycles is enough here and keeps the sim short
        repeat (2) @(posedge clk);
    endtask

    task automatic send_block(input logic [127:0] v);
        for (int i = 0; i < 16; i++)
            send_byte(v[127 - 8*i -: 8]);   // msb first
    endtask

    // wait until byte number `target` has been handed to the stub. absolute,
    // not "n more from here" - the overrun test carries on sending while the
    // bridge is already replying, so some of the reply is in by the time it
    // asks and a relative count would wait for 16 that never come.
    task automatic wait_until(input int target);
        while (sent_n < target) @(posedge clk);
    endtask

    task automatic collect(input int base, output logic [127:0] v);
        for (int i = 0; i < 16; i++)
            v[127 - 8*i -: 8] = sent[base + i];
    endtask

    task automatic do_key(input logic [127:0] k);
        send_byte(8'h4b);       // 'K'
        send_block(k);
        // 'K' is silent, so wait for the bridge to come back to idle by
        // giving it room - the whole load is ~40 axi cycles
        repeat (200) @(posedge clk);
    endtask

    task automatic do_encrypt(input logic [127:0] pt, input logic [127:0] exp_ct,
                              input string what);
        int           base;
        logic [127:0] ct;
        base = sent_n;
        send_byte(8'h45);       // 'E'
        send_block(pt);
        wait_until(base + 16);
        collect(base, ct);
        if (ct !== exp_ct) begin
            $display("FAIL: %s pt=%032x -> %032x, expected %032x", what, pt, ct, exp_ct);
            errors++;
        end
        n++;
    endtask

    task automatic do_status(output logic [7:0] s);
        int base;
        base = sent_n;
        send_byte(8'h53);       // 'S'
        wait_until(base + 1);
        s = sent[base];
    endtask

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

    // ---- tests ----

    logic [127:0] vk, vpt, vct, ct;
    logic [7:0]   s;
    int           fd, nline, e0, base, found;

    // does this 128 bit value contain a byte that is also a command byte
    function automatic bit has_cmd_byte(input logic [127:0] v);
        for (int i = 0; i < 16; i++)
            if (v[8*i +: 8] == 8'h4b || v[8*i +: 8] == 8'h45 || v[8*i +: 8] == 8'h53)
                return 1'b1;
        return 1'b0;
    endfunction

    // the ladder from the board bring-up plan, so the sim rehearses exactly
    // what I am going to type at the board
    localparam logic [127:0] K0   = 128'h0;
    localparam logic [127:0] KSEQ = 128'h000102030405060708090a0b0c0d0e0f;
    localparam logic [127:0] CT_A = 128'h66e94bd4ef8a2c3b884cfa59ca342b2e;
    localparam logic [127:0] CT_B = 128'h7aca0fd9bcd6ec7c9f97466616e6a282;
    localparam logic [127:0] CT_C = 128'hc6a13b37878f5b826f4f8162a1c8d879;
    localparam logic [127:0] CT_D = 128'h0a940bb5416ef045f1c39458c653ea5a;

    initial begin
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        // 1. status before anything has been loaded. nothing is ready,
        //    nothing is busy, nothing is done.
        e0 = errors;
        do_status(s);
        if (s !== 8'h00) begin
            $display("FAIL: STATUS out of reset = %02x, expected 00", s);
            errors++;
        end else begin
            $display("PASS: 'S' out of reset reads 00");
        end

        // 2. the bring-up ladder, A through D. A first because every input
        //    word is identical there, so word order cannot matter - if A
        //    fails it is something more basic than ordering.
        e0 = errors;
        do_key(K0);
        do_status(s);
        if (s[0] !== 1'b1) begin
            $display("FAIL: KEY_READY not set after 'K', STATUS = %02x", s);
            errors++;
        end
        do_encrypt(K0,   CT_A, "ladder A");
        do_encrypt(KSEQ, CT_B, "ladder B");
        do_key(KSEQ);
        do_encrypt(K0,   CT_C, "ladder C");
        do_encrypt(KSEQ, CT_D, "ladder D");
        if (errors == e0)
            $display("PASS: bring-up ladder A-D");

        // 3. the fips kat, read from the vector file rather than typed in
        e0 = errors;
        fd = open_vec("fips197_kat.txt");
        if ($fscanf(fd, "%h %h %h", vk, vpt, vct) != 3) begin
            $display("FAIL: bad fips197_kat.txt");
            $finish;
        end
        $fclose(fd);
        do_key(vk);
        do_encrypt(vpt, vct, "fips kat");
        if (errors == e0)
            $display("PASS: FIPS-197 KAT through the bridge");

        // 4. status after an encryption: key_ready and done, not busy
        e0 = errors;
        do_status(s);
        if (s !== 8'h05) begin
            $display("FAIL: STATUS after an encryption = %02x, expected 05", s);
            errors++;
        end else begin
            $display("PASS: 'S' after an encryption reads 05");
        end

        // 5. load the key once, stream blocks. this is the case the separate
        //    key_load/start exists for, and it is also what catches a poll
        //    that latched a stale DONE - block 2 would come back with block
        //    1's ciphertext.
        //    every line of random_1000.txt uses a different key, so the
        //    stream is built from the two ladder keys instead - those came
        //    out of the same python model, just typed in rather than read.
        e0 = errors;
        do_key(K0);
        do_encrypt(K0,   CT_A, "stream same key 1");
        do_encrypt(KSEQ, CT_B, "stream same key 2");
        do_encrypt(K0,   CT_A, "stream same key 3");
        do_encrypt(KSEQ, CT_B, "stream same key 4");
        if (errors == e0)
            $display("PASS: key loaded once, %0d blocks streamed", 4);

        // 6. junk in front of a command. the bridge should drop anything
        //    that is not K/E/S and still take the next real command - if it
        //    did not, one noise byte on the line would wedge the board until
        //    a reset.
        e0 = errors;
        send_byte(8'h00);
        send_byte(8'hff);
        send_byte(8'h6b);       // lowercase 'k' is not a command
        send_byte(8'h0a);       // a stray newline from a terminal
        do_status(s);
        if (s !== 8'h05) begin
            $display("FAIL: after junk bytes STATUS = %02x, expected 05", s);
            errors++;
        end
        do_key(K0);
        do_encrypt(K0, CT_A, "after junk");
        if (errors == e0)
            $display("PASS: junk bytes dropped, bridge resyncs");

        // 7. a payload byte that happens to equal a command byte has to be
        //    taken as data. 'K' is 0x4b, 'E' is 0x45 and 'S' is 0x53, and
        //    those turn up inside real keys and plaintexts constantly - if
        //    the arg collector ever peeked at the value the board would fail
        //    on about one block in twenty and look random doing it.
        //    Expected ciphertexts come from the vector file, not from me, so
        //    scan for lines that contain one of the three bytes anywhere.
        e0 = errors;
        fd    = open_vec("random_1000.txt");
        nline = 0;
        found = 0;
        while (nline < 200 && found < 3 && $fscanf(fd, "%h %h %h", vk, vpt, vct) == 3) begin
            nline++;
            if (has_cmd_byte(vpt) || has_cmd_byte(vk)) begin
                found++;
                do_key(vk);
                do_encrypt(vpt, vct, $sformatf("command byte inside the payload %0d", found));
            end
        end
        $fclose(fd);
        if (found == 0) begin
            $display("FAIL: no vector in the first %0d lines contained a K/E/S byte", nline);
            errors++;
        end else if (errors == e0) begin
            $display("PASS: %0d vectors containing K/E/S bytes treated as data", found);
        end

        // 8. overrun. send a command and then keep talking while the bridge
        //    is working. the extra bytes have nowhere to go, and the flag is
        //    what tells the board that happened instead of the host getting
        //    a wrong answer back.
        e0 = errors;
        if (overrun !== 1'b0) begin
            $display("FAIL: overrun set before anything overran it");
            errors++;
        end
        // test 7 left whatever key its last vector used loaded, so put a
        // known one back first - I got caught by that once already
        do_key(K0);
        base = sent_n;
        send_byte(8'h45);       // 'E'
        send_block(K0);
        // do not wait for the 16 bytes, just keep sending
        send_byte(8'h53);
        send_byte(8'h53);
        wait_until(base + 16);
        collect(base, ct);
        if (ct !== CT_A) begin
            $display("FAIL: overrun run gave %032x, expected %032x", ct, CT_A);
            errors++;
        end
        if (overrun !== 1'b1) begin
            $display("FAIL: bytes were dropped but overrun never latched");
            errors++;
        end
        if (errors == e0)
            $display("PASS: bytes arriving mid command are flagged, not silently mixed in");

        // 9. reset in the middle of a command, then carry on. this is the
        //    board's reset button pressed at the worst moment.
        e0 = errors;
        send_byte(8'h45);       // 'E'
        send_byte(8'h11);
        send_byte(8'h22);
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (4) @(posedge clk);
        sent_n = 0;
        if (overrun !== 1'b0 || resp_err !== 1'b0 || status_o !== 8'h00) begin
            $display("FAIL: reset did not clear the sticky flags (ovr=%b err=%b st=%02x)",
                     overrun, resp_err, status_o);
            errors++;
        end
        do_status(s);
        if (s !== 8'h00) begin
            $display("FAIL: STATUS after reset = %02x, expected 00", s);
            errors++;
        end
        do_key(K0);
        do_encrypt(K0, CT_A, "after reset mid command");

        //     and again with a transaction actually in flight. the case
        //     above resets while the bridge is sitting in C_ARG waiting for
        //     bytes, which is the easy one - nothing is on the bus. this one
        //     resets right after the last payload byte, while the writes and
        //     the status polls are going, which is the only way to catch a
        //     VALID that is not gated by reset.
        send_byte(8'h45);       // 'E'
        send_block(K0);
        repeat (6) @(posedge clk);      // mid axi burst
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (4) @(posedge clk);
        sent_n = 0;
        do_key(K0);
        do_encrypt(K0, CT_A, "after reset mid axi burst");
        if (errors == e0)
            $display("PASS: reset mid command and mid bus transaction, both recover");

        // 10. the transmitter stub at different speeds. tx_busy_len = 0 is
        //     a transmitter that never looks busy, which is the case the
        //     one dead cycle in C_TX_W has to survive; the long one is a
        //     transmitter slower than the bridge, which is what the real
        //     868 divisor actually looks like.
        e0 = errors;
        tx_busy_len = 0;
        do_encrypt(KSEQ, CT_B, "tx stub never busy");
        tx_busy_len = 1;
        do_encrypt(K0, CT_A, "tx stub busy 1 cycle");
        tx_busy_len = 40;
        do_encrypt(KSEQ, CT_B, "tx stub busy 40 cycles");
        tx_busy_len = 12;
        if (errors == e0)
            $display("PASS: transmit handshake holds at busy = 0, 1 and 40 cycles");

        // 11. soak. every line of the vector file is a fresh key and a fresh
        //     plaintext, so this is 'K' then 'E' over and over with the
        //     python model as the judge.
        e0 = errors;
        fd    = open_vec("random_1000.txt");
        nline = 0;
        while (nline < N_SOAK && $fscanf(fd, "%h %h %h", vk, vpt, vct) == 3) begin
            nline++;
            do_key(vk);
            do_encrypt(vpt, vct, $sformatf("soak %0d", nline));
        end
        $fclose(fd);
        if (errors == e0)
            $display("PASS: %0d vectors through the command protocol", nline);

        // 12. 'E' with no key loaded. the wrapper drops START unless
        //     KEY_READY is set, so without the check in C_CHK the bridge
        //     would poll STATUS.DONE forever and the board would just stop
        //     answering. It should drop the command, latch cmd_err, send
        //     nothing back, and still be listening afterwards.
        //     Found by mutation testing: "poll !busy instead of DONE" passed
        //     everything, and working out why led straight here.
        e0 = errors;
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (4) @(posedge clk);
        sent_n = 0;
        if (cmd_err !== 1'b0) begin
            $display("FAIL: cmd_err set straight out of reset");
            errors++;
        end
        send_byte(8'h45);       // 'E' with nothing loaded
        send_block(KSEQ);
        repeat (400) @(posedge clk);   // way longer than a real block takes
        if (sent_n != 0) begin
            $display("FAIL: 'E' with no key sent %0d bytes back, expected none", sent_n);
            errors++;
        end
        if (cmd_err !== 1'b1) begin
            $display("FAIL: 'E' with no key did not latch cmd_err");
            errors++;
        end
        // and the bridge is still alive
        do_status(s);
        if (s !== 8'h00) begin
            $display("FAIL: STATUS after a dropped 'E' = %02x, expected 00", s);
            errors++;
        end
        do_key(K0);
        do_encrypt(K0, CT_A, "after a dropped 'E'");
        if (errors == e0)
            $display("PASS: 'E' with no key is dropped, flagged, and does not wedge");

        // 13. everything again with the bus stalled. up to 4 cycles of delay
        //     on each of the five channels, independently, so AWVALID sits
        //     waiting on AWREADY, W arrives after AW, and responses come back
        //     late. Without this the master's handshake logic is never really
        //     tested - the wrapper is combinationally ready, so VALID and
        //     READY always go up together and a master that dropped VALID
        //     early would look identical.
        e0 = errors;
        stall_max = 4;
        do_key(K0);
        do_encrypt(K0,   CT_A, "stalled ladder A");
        do_encrypt(KSEQ, CT_B, "stalled ladder B");
        do_key(KSEQ);
        do_encrypt(K0,   CT_C, "stalled ladder C");
        do_encrypt(KSEQ, CT_D, "stalled ladder D");
        do_status(s);
        if (s !== 8'h05) begin
            $display("FAIL: stalled STATUS = %02x, expected 05", s);
            errors++;
        end
        fd    = open_vec("random_1000.txt");
        nline = 0;
        while (nline < 10 && $fscanf(fd, "%h %h %h", vk, vpt, vct) == 3) begin
            nline++;
            do_key(vk);
            do_encrypt(vpt, vct, $sformatf("stalled soak %0d", nline));
        end
        $fclose(fd);
        stall_max = 0;
        if (errors == e0)
            $display("PASS: ladder + %0d vectors with all five channels stalled", nline);

        // 14. nothing should ever have complained about a response
        if (resp_err !== 1'b0) begin
            $display("FAIL: resp_err latched, the slave answered something other than OKAY");
            errors++;
        end

        if (errors == 0)
            $display("PASS: uart_axi_bridge, %0d blocks over the command protocol", n);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
