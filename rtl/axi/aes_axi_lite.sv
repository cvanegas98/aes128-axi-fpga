// AXI4-Lite slave wrapper around aes_core.
// Register map is in docs/register_map.md - keep them in sync.
//
// 32 bit data, 64 byte aperture, so addr[5:2] picks one of 16 words (we use
// 14 of them). Write and read channels each get their own little 2 state fsm.
//
// The write side waits until AWVALID and WVALID are both up and then takes
// the address and the data in the same cycle. That's legal - AXI says READY
// is allowed to depend on VALID, it's only VALID that can't wait on READY -
// and it saves holding a separate latched address. Costs a cycle if a master
// sends the address early, which I don't care about here.
//
// Everything responds OKAY. Writing to a read only register or an unmapped
// hole is accepted and thrown away, because erroring out on AXI means DECERR
// and that's more trouble than it's worth for a core this small.

`timescale 1ns / 1ps

module aes_axi_lite #(
    parameter int ADDR_WIDTH = 6
) (
    // AXI4-Lite slave
    input  logic                   s_axi_aclk,
    input  logic                   s_axi_aresetn,   // active low, AXI style

    input  logic [ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  logic                   s_axi_awvalid,
    output logic                   s_axi_awready,

    input  logic [31:0]            s_axi_wdata,
    input  logic [3:0]             s_axi_wstrb,
    input  logic                   s_axi_wvalid,
    output logic                   s_axi_wready,

    output logic [1:0]             s_axi_bresp,
    output logic                   s_axi_bvalid,
    input  logic                   s_axi_bready,

    input  logic [ADDR_WIDTH-1:0]  s_axi_araddr,
    input  logic                   s_axi_arvalid,
    output logic                   s_axi_arready,

    output logic [31:0]            s_axi_rdata,
    output logic [1:0]             s_axi_rresp,
    output logic                   s_axi_rvalid,
    input  logic                   s_axi_rready,

    output logic                   irq
);

    // word offsets, i.e. addr[5:2]
    localparam logic [3:0] A_CTRL   = 4'h0;   // 0x00
    localparam logic [3:0] A_STATUS = 4'h1;   // 0x04
    localparam logic [3:0] A_KEY0   = 4'h2;   // 0x08 .. 0x14
    localparam logic [3:0] A_DIN0   = 4'h6;   // 0x18 .. 0x24
    localparam logic [3:0] A_DOUT0  = 4'hA;   // 0x28 .. 0x34

    localparam logic [1:0] RESP_OKAY = 2'b00;

    // core hookup
    logic         rst;
    logic         key_load, start;
    logic [127:0] key, plaintext, ciphertext;
    logic         key_ready, done, busy;

    assign rst = ~s_axi_aresetn;

    aes_core u_aes_core (
        .clk        (s_axi_aclk),
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

    // register file. key_w[0] is the msb word so {key_w[0..3]} lines up with
    // the hex string, see the word order section in the register map
    logic [31:0] key_w [0:3];
    logic [31:0] din_w [0:3];
    logic        irq_en;

    assign key       = {key_w[0], key_w[1], key_w[2], key_w[3]};
    assign plaintext = {din_w[0], din_w[1], din_w[2], din_w[3]};
    assign irq       = done && irq_en;

    // byte enables. AXI4-Lite masters are allowed to do partial writes so I
    // may as well honor wstrb instead of pretending it's always 4'hf
    function automatic logic [31:0] wr_bytes(input logic [31:0] old,
                                             input logic [31:0] nw,
                                             input logic [3:0]  strb);
        logic [31:0] r;
        for (int i = 0; i < 4; i++)
            r[8*i +: 8] = strb[i] ? nw[8*i +: 8] : old[8*i +: 8];
        return r;
    endfunction

    // ---- write channel ----

    typedef enum logic {W_IDLE, W_RESP} wstate_e;
    wstate_e wstate;

    logic       wr_fire;
    logic [3:0] wr_word;

    assign wr_fire = (wstate == W_IDLE) && s_axi_awvalid && s_axi_wvalid;
    assign wr_word = s_axi_awaddr[5:2];

    assign s_axi_awready = wr_fire;
    assign s_axi_wready  = wr_fire;
    assign s_axi_bvalid  = (wstate == W_RESP);
    assign s_axi_bresp   = RESP_OKAY;

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            wstate   <= W_IDLE;
            key_load <= 1'b0;
            start    <= 1'b0;
            irq_en   <= 1'b0;
            for (int i = 0; i < 4; i++) begin
                key_w[i] <= 32'h0;
                din_w[i] <= 32'h0;
            end
        end else begin
            // default so these come out as one cycle pulses
            key_load <= 1'b0;
            start    <= 1'b0;

            case (wstate)
                W_IDLE: begin
                    if (wr_fire) begin
                        wstate <= W_RESP;

                        if (wr_word == A_CTRL) begin
                            // ctrl bits live in the low byte, so a master that
                            // masks it off isn't writing ctrl at all
                            if (s_axi_wstrb[0]) begin
                                irq_en <= s_axi_wdata[2];
                                // both ignored while the core is working, and
                                // key_load wins if software sets both
                                if (!busy) begin
                                    if (s_axi_wdata[0])
                                        key_load <= 1'b1;
                                    else if (s_axi_wdata[1] && key_ready)
                                        start <= 1'b1;
                                end
                            end
                        end else if (wr_word >= A_KEY0 && wr_word < A_KEY0 + 4) begin
                            key_w[wr_word - A_KEY0] <=
                                wr_bytes(key_w[wr_word - A_KEY0], s_axi_wdata, s_axi_wstrb);
                        end else if (wr_word >= A_DIN0 && wr_word < A_DIN0 + 4) begin
                            din_w[wr_word - A_DIN0] <=
                                wr_bytes(din_w[wr_word - A_DIN0], s_axi_wdata, s_axi_wstrb);
                        end
                        // status, dout and the holes: accepted, ignored
                    end
                end

                W_RESP: begin
                    if (s_axi_bready)
                        wstate <= W_IDLE;
                end

                default: wstate <= W_IDLE;
            endcase
        end
    end

    // ---- read channel ----

    typedef enum logic {R_IDLE, R_RESP} rstate_e;
    rstate_e rstate;

    logic       rd_fire;
    logic [3:0] rd_word;
    logic [31:0] rd_data;

    assign rd_fire = (rstate == R_IDLE) && s_axi_arvalid;
    assign rd_word = s_axi_araddr[5:2];

    assign s_axi_arready = rd_fire;
    assign s_axi_rvalid  = (rstate == R_RESP);
    assign s_axi_rresp   = RESP_OKAY;

    always_comb begin
        // unmapped holes and the ctrl pulse bits read back 0
        rd_data = 32'h0;
        if (rd_word == A_CTRL)
            rd_data = {29'h0, irq_en, 2'b00};
        else if (rd_word == A_STATUS)
            rd_data = {29'h0, done, busy, key_ready};
        else if (rd_word >= A_KEY0 && rd_word < A_KEY0 + 4)
            rd_data = key_w[rd_word - A_KEY0];
        else if (rd_word >= A_DIN0 && rd_word < A_DIN0 + 4)
            rd_data = din_w[rd_word - A_DIN0];
        else if (rd_word >= A_DOUT0 && rd_word < A_DOUT0 + 4)
            rd_data = ciphertext[127 - 32*(rd_word - A_DOUT0) -: 32];
    end

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            rstate      <= R_IDLE;
            s_axi_rdata <= 32'h0;
        end else begin
            case (rstate)
                R_IDLE: begin
                    if (rd_fire) begin
                        s_axi_rdata <= rd_data;   // sample at accept
                        rstate      <= R_RESP;
                    end
                end

                R_RESP: begin
                    if (s_axi_rready)
                        rstate <= R_IDLE;
                end

                default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule
