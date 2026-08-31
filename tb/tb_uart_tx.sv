// uart_tx testbench.
//
// The decoder here is bit banged from the 8N1 definition rather than being
// a uart_rx instance, for the same reason tb_uart_rx doesn't use uart_tx to
// make its stimulus: two modules I wrote from the same idea would agree with
// each other even if the idea was wrong. There IS a loopback test at the end,
// but it runs after both sides have been checked independently - on its own
// it would prove nothing more than that they're consistent.
//
// Also checks the bit period in real time, at both the fast sim divisor and
// the actual 868 the board will use.
//
// from the repo root:
//   xvlog -sv rtl/uart/uart_tx.sv rtl/uart/uart_rx.sv tb/tb_uart_tx.sv
//   xelab tb_uart_tx -s tb_uart_tx_sim
//   xsim tb_uart_tx_sim -R

`timescale 1ns / 1ps

module tb_uart_tx;

    localparam int CPB      = 16;
    localparam int BIT_NS   = CPB * 10;      // 10ns clock
    localparam int CPB_REAL = 868;           // 100 MHz / 115200
    localparam int BIT_REAL = CPB_REAL * 10; // 8680 ns

    logic       clk = 0;
    logic       rst;
    logic       send = 1'b0;
    logic [7:0] data = 8'h0;
    logic       tx, busy;

    // the real divisor instance, only used for the timing check
    logic       send_r = 1'b0;
    logic [7:0] data_r = 8'h0;
    logic       tx_r, busy_r;

    int errors = 0;

    uart_tx #(.CLKS_PER_BIT(CPB)) dut (
        .clk (clk), .rst (rst), .send (send), .data (data),
        .tx  (tx),  .busy (busy)
    );

    uart_tx #(.CLKS_PER_BIT(CPB_REAL)) dut_real (
        .clk (clk), .rst (rst), .send (send_r), .data (data_r),
        .tx  (tx_r), .busy (busy_r)
    );

    always #5 clk = ~clk;

    initial begin
        #500us;
        $display("FAIL: watchdog timeout, something hung");
        $finish;
    end

    // wait out the previous byte first. the decoder samples the stop bit at
    // its midpoint and returns half a bit before the frame is actually over,
    // so without this the next send lands while busy is still high, gets
    // ignored (correctly), and the decoder then waits forever for a start
    // bit that never comes.
    task automatic tx_byte(input logic [7:0] b);
        wait (!busy);
        @(posedge clk);
        data <= b;
        send <= 1'b1;
        @(posedge clk);
        send <= 1'b0;
    endtask

    // independent 8N1 decoder, straight from the spec
    task automatic recv_frame(output logic [7:0] b, output bit ok);
        ok = 1'b1;
        @(negedge tx);              // start bit
        #(BIT_NS/2 + 1);            // middle of it, offset off the clock edge
        if (tx !== 1'b0) ok = 1'b0;
        for (int i = 0; i < 8; i++) begin
            #(BIT_NS);
            b[i] = tx;              // lsb first
        end
        #(BIT_NS);
        if (tx !== 1'b1) ok = 1'b0; // stop bit
    endtask

    logic [7:0] pat [0:7];
    logic [7:0] got;
    bit         ok;
    time        t0, t1;

    initial begin
        pat[0] = 8'h00; pat[1] = 8'hff; pat[2] = 8'h55; pat[3] = 8'haa;
        pat[4] = 8'h01; pat[5] = 8'h80; pat[6] = 8'h3c; pat[7] = 8'h7e;

        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        if (tx !== 1'b1) begin
            $display("FAIL: tx idle level is %b, should be high", tx);
            errors++;
        end

        // 1. each pattern out and independently decoded back
        for (int i = 0; i < 8; i++) begin
            wait (!busy);
            repeat (2) @(posedge clk);
            fork
                tx_byte(pat[i]);
                recv_frame(got, ok);
            join
            if (!ok) begin
                $display("FAIL: frame %0d malformed (start or stop bit wrong)", i);
                errors++;
            end else if (got !== pat[i]) begin
                $display("FAIL: sent %02x, decoded %02x", pat[i], got);
                errors++;
            end
        end
        if (errors == 0) $display("PASS: 8 patterns transmitted lsb first");

        // 2. busy behaviour, and that send is ignored while busy. 0xff means
        //    tx is low for exactly the start bit, so a byte that got stomped
        //    would show up as a wrong decode.
        wait (!busy);
        repeat (2) @(posedge clk);
        data <= 8'h3c;
        send <= 1'b1;
        @(posedge clk);
        send <= 1'b0;
        @(posedge clk);
        if (!busy) begin
            $display("FAIL: busy didn't rise after send");
            errors++;
        end
        fork
            begin   // hammer send while it's mid byte
                repeat (5) begin
                    repeat (CPB) @(posedge clk);
                    data <= 8'h00;
                    send <= 1'b1;
                    @(posedge clk);
                    send <= 1'b0;
                end
            end
            begin
                recv_frame(got, ok);
                if (got !== 8'h3c) begin
                    $display("FAIL: send during busy corrupted the byte: %02x", got);
                    errors++;
                end
            end
        join
        wait (!busy);
        $display("PASS: send ignored while busy");

        // 3. bit period at the sim divisor. 0xff is low for the start bit
        //    only, so negedge to posedge is exactly one bit.
        wait (!busy);
        repeat (2) @(posedge clk);
        fork
            tx_byte(8'hff);
            begin
                @(negedge tx); t0 = $time;
                @(posedge tx); t1 = $time;
            end
        join
        if ((t1 - t0) != BIT_NS) begin
            $display("FAIL: bit period %0t, expected %0t", t1 - t0, BIT_NS);
            errors++;
        end else begin
            $display("PASS: bit period is %0t at CLKS_PER_BIT=%0d", t1 - t0, CPB);
        end
        wait (!busy);

        // 4. same measurement on the divisor the board actually uses. this is
        //    the number that decides whether the thing talks to a terminal at
        //    all - 8.68us per bit is 115200 baud.
        fork
            begin
                @(posedge clk);
                data_r <= 8'hff;
                send_r <= 1'b1;
                @(posedge clk);
                send_r <= 1'b0;
            end
            begin
                @(negedge tx_r); t0 = $time;
                @(posedge tx_r); t1 = $time;
            end
        join
        if ((t1 - t0) != BIT_REAL) begin
            $display("FAIL: real bit period %0t, expected %0t (115200 baud)", t1 - t0, BIT_REAL);
            errors++;
        end else begin
            $display("PASS: %0t per bit at CLKS_PER_BIT=%0d, i.e. 115200 baud", t1 - t0, CPB_REAL);
        end

        if (errors == 0)
            $display("PASS: uart_tx");
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
