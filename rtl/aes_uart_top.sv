// Board top level for the Basys 3. Ties the uart to the bridge to the axi
// wrapper, and that is all it does - no logic of its own beyond the reset
// synchronizer and the leds.
//
//   RsRx --> uart_rx --> uart_axi_bridge --> aes_axi_lite --> aes_core
//   RsTx <-- uart_tx <--/
//
// CLKS_PER_BIT is a parameter so the testbench can run the whole chain at a
// small divisor and still finish this decade. On the board it is the default
// 868: 100 MHz / 115200 baud.
//
// Reset is btnC through two flops. The button is asynchronous to the 100 MHz
// clock and it is bouncy, but bounce does not matter for a reset - what does
// matter is that the release edge lands somewhere definite, and two flops
// gives every flop in the design the same view of it. aes_axi_lite wants
// active low (AXI convention) and everything else wants active high, so both
// polarities come off the same synchronized signal rather than off separate
// logic that could disagree by a cycle.
//
// Nothing resets rst_sync itself and nothing needs to. On Artix-7 every flop
// comes out of configuration at 0, so rst_sync starts at 0 (not in reset) and
// every state register in the design starts in the state its own reset branch
// would have put it in - idle FSMs, cleared flags, DOUT zero. btnC is there to
// get back to that from a wedged state, not to reach it the first time.
//
// LEDs, because when the serial link is not working the board is the only
// thing that can tell you anything:
//   led[0] key_ready   \
//   led[1] busy         >  the last STATUS byte the bridge read over AXI
//   led[2] done        /
//   led[3] overrun     a command byte arrived while the bridge was busy
//   led[4] frame_err   a stop bit was low - usually the wrong baud rate
//   led[5] resp_err    an AXI response was not OKAY (should never light)
//   led[6] cmd_err     an 'E' arrived with no key loaded, so it was dropped
//   led[15] heartbeat  ~1.5 Hz. if this is dark the clock or the bitstream
//                      is wrong, which is worth knowing before blaming the
//                      cipher.
//
// frame_err and overrun latch until reset. A one cycle blink at 100 MHz is
// invisible, and these are exactly the failures you want to still see
// evidence of after the fact.

`timescale 1ns / 1ps

module aes_uart_top #(
    parameter int CLKS_PER_BIT = 868    // 100 MHz / 115200
) (
    input  logic        clk,            // W5, 100 MHz
    input  logic        btnC,           // reset, active high
    input  logic        RsRx,           // serial in  from the usb-uart
    output logic        RsTx,           // serial out to the usb-uart
    output logic [15:0] led
);

    // ---- reset synchronizer ----
    //
    // ASYNC_REG tells the tools these two flops are a synchronizer, so they
    // get placed in the same slice and left alone by retiming. It changes no
    // behaviour and simulation cannot tell the difference either way - what
    // the second flop actually buys is metastability MTBF, which an event
    // driven simulator does not model at all. The attribute is the only place
    // that intent is written down where a tool can act on it.
    (* ASYNC_REG = "TRUE" *) logic [1:0] rst_sync;
    logic       rst;
    logic       aresetn;

    always_ff @(posedge clk)
        rst_sync <= {rst_sync[0], btnC};

    assign rst     = rst_sync[1];
    assign aresetn = ~rst_sync[1];

    // ---- uart ----
    logic [7:0] rx_data;
    logic       rx_valid, rx_frame_err;
    logic [7:0] tx_data;
    logic       tx_send, tx_busy;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk       (clk),
        .rst       (rst),
        .rx        (RsRx),
        .data      (rx_data),
        .valid     (rx_valid),
        .frame_err (rx_frame_err)
    );

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk  (clk),
        .rst  (rst),
        .send (tx_send),
        .data (tx_data),
        .tx   (RsTx),
        .busy (tx_busy)
    );

    // ---- bridge (axi master) ----
    logic [5:0]  awaddr, araddr;
    logic [2:0]  awprot, arprot;
    logic        awvalid, awready, arvalid, arready;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic        wvalid, wready;
    logic [1:0]  bresp, rresp;
    logic        bvalid, bready, rvalid, rready;

    logic [7:0]  status_o;
    logic        overrun, resp_err, cmd_err;

    uart_axi_bridge u_bridge (
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

    // ---- axi slave + the core ----
    aes_axi_lite u_axi (
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
        .irq           ()              // no interrupt controller on the board,
                                       // the bridge polls STATUS instead
    );

    // ---- leds ----
    logic        frame_err_sticky;
    logic [25:0] hb;

    always_ff @(posedge clk) begin
        if (rst) begin
            frame_err_sticky <= 1'b0;
            hb               <= 26'd0;
        end else begin
            if (rx_valid && rx_frame_err) frame_err_sticky <= 1'b1;
            hb <= hb + 26'd1;
        end
    end

    always_comb begin
        led        = 16'h0;
        led[2:0]   = status_o[2:0];    // key_ready, busy, done
        led[3]     = overrun;
        led[4]     = frame_err_sticky;
        led[5]     = resp_err;
        led[6]     = cmd_err;
        led[15]    = hb[25];           // 100 MHz / 2^26 = ~1.5 Hz
    end

endmodule
