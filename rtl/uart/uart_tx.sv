// UART transmitter, 8N1, no flow control. Companion to uart_rx.sv.
//
// Pulse send with data valid and it shifts out start, 8 data bits lsb first,
// then one stop bit. busy is high the whole time; send is ignored while busy
// so a byte can't be stomped halfway out.
//
// tx is a registered output - it's going to a pin, and registering it keeps
// the output timing off whatever combinational path the fsm turned into.
// That costs one cycle of skew per bit boundary, which against a 868 cycle
// bit period is nothing, and it's the same skew on every bit so it doesn't
// accumulate.

`timescale 1ns / 1ps

module uart_tx #(
    parameter int CLKS_PER_BIT = 868
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       send,       // one cycle pulse, ignored while busy
    input  logic [7:0] data,
    output logic       tx,
    output logic       busy
);

    typedef enum logic [1:0] {S_IDLE, S_START, S_DATA, S_STOP} state_e;
    state_e cs;

    logic [$clog2(CLKS_PER_BIT)-1:0] cnt;
    logic [2:0]                      bit_idx;
    logic [7:0]                      sh;

    assign busy = (cs != S_IDLE);

    always_ff @(posedge clk) begin
        if (rst) begin
            cs      <= S_IDLE;
            cnt     <= '0;
            bit_idx <= 3'd0;
            sh      <= 8'h0;
            tx      <= 1'b1;    // idle line is high
        end else begin
            case (cs)
                S_IDLE: begin
                    tx  <= 1'b1;
                    cnt <= '0;
                    if (send) begin
                        sh <= data;
                        cs <= S_START;
                    end
                end

                S_START: begin
                    tx <= 1'b0;
                    if (cnt == CLKS_PER_BIT[$bits(cnt)-1:0] - 1'b1) begin
                        cnt     <= '0;
                        bit_idx <= 3'd0;
                        cs      <= S_DATA;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    tx <= sh[0];
                    if (cnt == CLKS_PER_BIT[$bits(cnt)-1:0] - 1'b1) begin
                        cnt <= '0;
                        sh  <= {1'b0, sh[7:1]};
                        if (bit_idx == 3'd7) cs      <= S_STOP;
                        else                 bit_idx <= bit_idx + 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    tx <= 1'b1;
                    if (cnt == CLKS_PER_BIT[$bits(cnt)-1:0] - 1'b1) begin
                        cnt <= '0;
                        cs  <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: cs <= S_IDLE;
            endcase
        end
    end

endmodule
