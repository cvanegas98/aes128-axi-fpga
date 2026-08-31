// uart_rx testbench.
//
// The stimulus is bit banged straight from the 8N1 definition - start bit
// low, eight data bits lsb first, stop bit high - and NOT generated with
// uart_tx. If I drove this with my own transmitter then any shared
// misunderstanding (lsb vs msb first being the obvious one) would cancel out
// and both modules would agree while both were wrong. Same lesson as the axi
// bfm agreeing with the axi slave because I wrote both.
//
// Runs with CLKS_PER_BIT = 16 so the sim is quick; the divisor only scales
// the counters, and tb_uart_tx checks a real 868 divisor produces a real
// 8.68us bit.
//
// from the repo root:
//   xvlog -sv rtl/uart/uart_rx.sv tb/tb_uart_rx.sv
//   xelab tb_uart_rx -s tb_uart_rx_sim
//   xsim tb_uart_rx_sim -R

`timescale 1ns / 1ps

module tb_uart_rx;

    localparam int CPB    = 16;
    localparam int BIT_NS = CPB * 10;   // 10ns clock

    logic       clk = 0;
    logic       rst;
    logic       rx = 1'b1;
    logic [7:0] data;
    logic       valid, frame_err;

    int errors = 0;

    uart_rx #(.CLKS_PER_BIT(CPB)) dut (
        .clk       (clk),
        .rst       (rst),
        .rx        (rx),
        .data      (data),
        .valid     (valid),
        .frame_err (frame_err)
    );

    always #5 clk = ~clk;

    initial begin
        #200us;
        $display("FAIL: watchdog timeout, something hung");
        $finish;
    end

    // catch every byte the receiver reports, so the test doesn't have to
    // race the valid pulse
    logic [7:0] got_data [0:63];
    logic       got_fe   [0:63];
    int         got_n = 0;

    always @(posedge clk) begin
        if (!rst && valid) begin
            got_data[got_n] = data;
            got_fe[got_n]   = frame_err;
            got_n++;
        end
    end

    // one 8N1 frame, written from the spec. gap_bits of idle afterwards.
    // bit_ns lets a test drive the frame at a deliberately wrong baud rate.
    task automatic send_frame(input logic [7:0] b,
                              input bit         good_stop = 1'b1,
                              input int         gap_bits  = 0,
                              input int         bit_ns    = BIT_NS);
        rx = 1'b0;                      // start bit
        #(bit_ns);
        for (int i = 0; i < 8; i++) begin
            rx = b[i];                  // lsb first
            #(bit_ns);
        end
        rx = good_stop;                 // stop bit
        #(bit_ns);
        rx = 1'b1;                      // idle
        if (gap_bits > 0) #(bit_ns * gap_bits);
    endtask

    task automatic expect_byte(input int idx, input logic [7:0] b, input string what);
        if (idx >= got_n) begin
            $display("FAIL: %s - no byte received at index %0d", what, idx);
            errors++;
        end else if (got_data[idx] !== b) begin
            $display("FAIL: %s - got %02x, expected %02x", what, got_data[idx], b);
            errors++;
        end
    endtask

    logic [7:0] pat [0:7];
    int         base;

    initial begin
        pat[0] = 8'h00; pat[1] = 8'hff; pat[2] = 8'h55; pat[3] = 8'haa;
        pat[4] = 8'h01; pat[5] = 8'h80; pat[6] = 8'h3c; pat[7] = 8'h7e;

        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        #1;   // keep every rx transition off the clock edge

        // 1. the patterns, with an idle gap between frames. 00 and ff cover
        //    the all zero / all one cases, 55 and aa catch a bit reversal,
        //    01 and 80 pin down which end is the lsb.
        for (int i = 0; i < 8; i++)
            send_frame(pat[i], 1'b1, 2);
        repeat (4 * CPB) @(posedge clk);

        if (got_n != 8) begin
            $display("FAIL: expected 8 bytes, got %0d", got_n);
            errors++;
        end
        for (int i = 0; i < 8; i++)
            expect_byte(i, pat[i], $sformatf("pattern %0d", i));
        for (int i = 0; i < got_n; i++)
            if (got_fe[i] !== 1'b0) begin
                $display("FAIL: spurious framing error on byte %0d", i);
                errors++;
            end
        if (errors == 0) $display("PASS: 8 patterns received lsb first");

        // 2. back to back frames, no idle at all between stop and next start
        base = got_n;
        for (int i = 0; i < 4; i++)
            send_frame(pat[i], 1'b1, 0);
        repeat (4 * CPB) @(posedge clk);
        if (got_n != base + 4) begin
            $display("FAIL: back to back, expected 4 more bytes, got %0d", got_n - base);
            errors++;
        end else begin
            for (int i = 0; i < 4; i++)
                expect_byte(base + i, pat[i], $sformatf("back to back %0d", i));
            $display("PASS: back to back frames with no idle gap");
        end

        // 3. a glitch on the line is not a start bit. quarter of a bit low,
        //    which is long enough to get through the synchronizer but short
        //    enough that the mid bit recheck sees the line back high.
        base = got_n;
        rx = 1'b0;
        #(BIT_NS / 4);
        rx = 1'b1;
        repeat (4 * CPB) @(posedge clk);
        if (got_n != base) begin
            $display("FAIL: a %0dns glitch was decoded as a byte (%02x)",
                     BIT_NS / 4, got_data[base]);
            errors++;
        end else begin
            $display("PASS: short glitch rejected, not treated as a start bit");
        end

        // 4. framing error - stop bit held low. the byte still comes out
        //    (that's what a real uart does) but frame_err flags it, which is
        //    what a wrong baud rate looks like on the board.
        base = got_n;
        send_frame(8'h5a, 1'b0, 2);
        repeat (4 * CPB) @(posedge clk);
        if (got_n != base + 1) begin
            $display("FAIL: bad stop bit, expected the byte anyway");
            errors++;
        end else if (got_fe[base] !== 1'b1) begin
            $display("FAIL: bad stop bit didn't set frame_err");
            errors++;
        end else begin
            expect_byte(base, 8'h5a, "framing error byte");
            $display("PASS: bad stop bit flagged as a framing error");
        end

        // 5. and the receiver still works after a bad frame
        base = got_n;
        send_frame(8'hc3, 1'b1, 2);
        repeat (4 * CPB) @(posedge clk);
        expect_byte(base, 8'hc3, "recovery after framing error");
        if (base + 1 == got_n && got_fe[base] === 1'b0)
            $display("PASS: receiver recovers after a framing error");
        else begin
            $display("FAIL: receiver didn't recover cleanly");
            errors++;
        end

        // 6. baud tolerance. this is the test that actually justifies sampling
        //    in the middle of each bit instead of near an edge - with
        //    perfectly timed stimulus the two are indistinguishable, so
        //    without this the mid bit logic is untested. the receiver frees
        //    itself on the start edge and then counts, so error accumulates
        //    over the 9.5 bits to the stop sample; half a bit of slack there
        //    is about +/-5%. Test +/-4%, which is well past the ~0.01% a real
        //    crystal pair drifts but proves the margin is real.
        base = got_n;
        send_frame(8'h5a, 1'b1, 2, (BIT_NS * 104) / 100);   // sender 4% slow
        send_frame(8'ha5, 1'b1, 2, (BIT_NS *  96) / 100);   // sender 4% fast
        repeat (8 * CPB) @(posedge clk);
        if (got_n != base + 2) begin
            $display("FAIL: baud skew, expected 2 bytes, got %0d", got_n - base);
            errors++;
        end else begin
            expect_byte(base,     8'h5a, "4% slow sender");
            expect_byte(base + 1, 8'ha5, "4% fast sender");
            if (got_fe[base] !== 1'b0 || got_fe[base+1] !== 1'b0) begin
                $display("FAIL: baud skew caused a framing error");
                errors++;
            end else begin
                $display("PASS: decodes correctly with +/-4%% baud error");
            end
        end

        if (errors == 0)
            $display("PASS: uart_rx, %0d bytes total", got_n);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
