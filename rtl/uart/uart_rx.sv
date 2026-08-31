// UART receiver, 8N1, no flow control.
//
// Written from scratch - the plan said reuse the uart from my old project but
// that turned out to be embedded C for a tm4c, so there was nothing to port.
//
// CLKS_PER_BIT is the clock divisor: 100 MHz / 115200 baud = 868.06, so 868.
// The 0.007% error is nothing, a byte drifts about a twentieth of a bit over
// its 10 bit frame.
//
// rx is asynchronous to clk, so it goes through two flops before anything
// looks at it. Without that, a transition landing near the clock edge can go
// metastable and you get byte corruption that never repeats the same way
// twice - which looks exactly like a broken cipher and isn't.
//
// Sampling: catch the falling edge of the start bit, wait half a bit to land
// in the middle of it, and check it's still low (a short glitch on the line
// is not a start bit). From there sample every CLKS_PER_BIT, which keeps
// every sample in the middle of its bit. Data is LSB first, then one stop
// bit which should be high - if it isn't, that's a framing error and usually
// means the baud rate is wrong.

`timescale 1ns / 1ps

module uart_rx #(
    parameter int CLKS_PER_BIT = 868
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx,          // raw async serial in
    output logic [7:0] data,
    output logic       valid,       // one cycle pulse when data is good
    output logic       frame_err    // stop bit wasn't high
);

    localparam int HALF_BIT = CLKS_PER_BIT / 2;

    typedef enum logic [1:0] {S_IDLE, S_START, S_DATA, S_STOP} state_e;
    state_e cs;

    // two flop synchronizer. reset high because idle line is high, so we
    // don't see a fake start bit coming out of reset.
    logic [1:0] rx_sync;
    logic       rx_s;
    assign rx_s = rx_sync[1];

    logic [$clog2(CLKS_PER_BIT)-1:0] cnt;
    logic [2:0]                      bit_idx;
    logic [7:0]                      sh;

    always_ff @(posedge clk) begin
        if (rst) rx_sync <= 2'b11;
        else     rx_sync <= {rx_sync[0], rx};
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            cs        <= S_IDLE;
            cnt       <= '0;
            bit_idx   <= 3'd0;
            sh        <= 8'h0;
            data      <= 8'h0;
            valid     <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            valid <= 1'b0;   // default, so it comes out as a one cycle pulse

            case (cs)
                S_IDLE: begin
                    cnt <= '0;
                    if (!rx_s) cs <= S_START;   // line went low, maybe a start bit
                end

                S_START: begin
                    if (cnt == HALF_BIT[$bits(cnt)-1:0]) begin
                        cnt <= '0;
                        if (!rx_s) begin
                            bit_idx <= 3'd0;
                            cs      <= S_DATA;  // still low at mid bit, it's real
                        end else begin
                            cs <= S_IDLE;       // just a glitch
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    if (cnt == CLKS_PER_BIT[$bits(cnt)-1:0] - 1'b1) begin
                        cnt <= '0;
                        sh  <= {rx_s, sh[7:1]};   // lsb first, so shift down
                        if (bit_idx == 3'd7) cs      <= S_STOP;
                        else                 bit_idx <= bit_idx + 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    if (cnt == CLKS_PER_BIT[$bits(cnt)-1:0] - 1'b1) begin
                        cnt       <= '0;
                        data      <= sh;
                        valid     <= 1'b1;
                        frame_err <= ~rx_s;   // stop bit should be high
                        cs        <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: cs <= S_IDLE;
            endcase
        end
    end

endmodule
