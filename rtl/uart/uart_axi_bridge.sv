// UART command bridge - an AXI4-Lite MASTER that drives aes_axi_lite.
//
// This is the "how software drives it" section of docs/register_map.md built
// in hardware. Three commands, byte oriented, MSB first like everything else
// in this project:
//
//   'K' + 16 bytes   write KEY0-3, pulse CTRL.KEY_LOAD, poll STATUS.KEY_READY
//   'E' + 16 bytes   write DIN0-3, pulse CTRL.START, poll STATUS.DONE,
//                    read DOUT0-3 and send the 16 ciphertext bytes back
//   'S'              read STATUS, send the low byte back
//
// The 16 bytes go in most significant first, same order as a hex string in
// the vector files, so a byte stream out of a python script drops straight in
// with no swapping.
//
// 'E' checks STATUS.KEY_READY before it starts anything. Without that check
// an 'E' sent before any 'K' wedges the board: the wrapper drops START when
// no key is loaded, so STATUS.DONE never arrives and the poll spins forever.
// Now the command is dropped, cmd_err latches for the led, and the host's
// read just times out. Mutation testing is what turned that up - see the
// note in docs/STATUS.md.
//
// Only 'E' and 'S' answer. 'K' is silent - the host either follows it with
// 'S' or just sends the next 'E', because the whole key load finishes in far
// less than one byte time. Anything that is not K/E/S gets thrown away and
// the bridge stays in C_CMD, so line noise or a half typed command cannot
// wedge it - it resyncs on the next real command byte. That mattered more
// to me than having an error response.
//
// The protocol is strictly request/response. If the host sends the next
// command before reading the answer to the last one, those bytes land while
// the bridge is off doing AXI work and get dropped - overrun latches so the
// board can light an LED instead of the host silently getting a wrong
// answer. No FIFO and no flow control on purpose: 16 ciphertext bytes take
// 1.4 ms to go out and any sane host is sitting there waiting for them.
//
// Two FSMs. The command FSM speaks the protocol and asks for one AXI
// transaction at a time; the bus engine under it does the handshakes.
// Keeping them apart means the protocol states do not have to think about
// AXI and the engine does not have to know what a key is.
//
// Timing note on the status poll, because it is the one real race in here.
// After the CTRL write the bridge polls STATUS, and STATUS.DONE is sticky
// from the previous block - so if the poll could read before the core
// reacted to START it would see a stale DONE and read out the old
// ciphertext. It cannot: the slave accepts the CTRL write 1 cycle after the
// engine raises AWVALID/WVALID, aes_core clears done 1 cycle after that,
// and meanwhile the engine still needs its B response and then a whole AR/R
// read before any status data comes back. That is about 3 cycles of margin
// on a 1 cycle race. Same argument for KEY_READY on 'K'. The tb pins it
// down by streaming several different blocks under one key - a stale DONE
// would hand back the previous ciphertext and the vector check catches it.
//
// The other reason this module is worth having: it is a second, independent
// AXI master against aes_axi_lite. My BFM and my slave were both written
// from the same mental model so they agree by construction. This one was
// written from the register map, and the protocol assertions in the tb
// watch it against the spec.

`timescale 1ns / 1ps

module uart_axi_bridge (
    input  logic        clk,
    input  logic        rst,          // active high

    // byte side (uart_rx / uart_tx)
    input  logic [7:0]  rx_data,
    input  logic        rx_valid,     // one cycle pulse
    output logic [7:0]  tx_data,
    output logic        tx_send,      // one cycle pulse
    input  logic        tx_busy,

    // AXI4-Lite master
    output logic [5:0]  m_axi_awaddr,
    output logic [2:0]  m_axi_awprot,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,

    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,

    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,

    output logic [5:0]  m_axi_araddr,
    output logic [2:0]  m_axi_arprot,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,

    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,

    // board side
    output logic [7:0]  status_o,     // last STATUS byte the bridge read
    output logic        overrun,      // sticky: a byte arrived while busy
    output logic        resp_err,     // sticky: a response was not OKAY
    output logic        cmd_err       // sticky: a command was dropped
);

    // register offsets, docs/register_map.md
    localparam logic [5:0] R_CTRL   = 6'h00;
    localparam logic [5:0] R_STATUS = 6'h04;
    localparam logic [5:0] R_KEY0   = 6'h08;
    localparam logic [5:0] R_DIN0   = 6'h18;
    localparam logic [5:0] R_DOUT0  = 6'h28;

    localparam int ST_KEY_READY = 0;
    localparam int ST_DONE      = 2;

    localparam logic [31:0] CTRL_KEY_LOAD = 32'h1;
    localparam logic [31:0] CTRL_START    = 32'h2;

    localparam logic [7:0] CMD_KEY    = 8'h4b;   // 'K'
    localparam logic [7:0] CMD_ENC    = 8'h45;   // 'E'
    localparam logic [7:0] CMD_STATUS = 8'h53;   // 'S'

    // ---- bus engine ----
    //
    // One outstanding transaction, which is all AXI4-Lite needs here.
    // AWVALID and WVALID go up together - the spec forbids a master waiting
    // for AWREADY before it drives WVALID, and this slave takes both in the
    // same cycle anyway. They come down independently though, because a
    // different slave is allowed to accept them on different cycles and I
    // would rather not build that assumption in.
    //
    // The VALID outputs are gated with !rst on the way out. The state regs
    // clear synchronously, so a transaction in flight when reset hits would
    // otherwise hold VALID high until the next edge, and the spec wants
    // VALID low while reset is asserted. Same fix the slave needed.

    typedef enum logic [2:0] {B_IDLE, B_W, B_B, B_AR, B_R} bstate_e;
    bstate_e bstate;

    logic        bus_req;      // one cycle pulse from the command fsm
    logic        bus_we;
    logic [5:0]  bus_addr;
    logic [31:0] bus_wdata;
    logic [31:0] bus_rdata;
    logic        bus_done;     // one cycle pulse when the transaction retires

    logic awvalid_r, wvalid_r, arvalid_r;

    assign m_axi_awvalid = awvalid_r && !rst;
    assign m_axi_wvalid  = wvalid_r  && !rst;
    assign m_axi_arvalid = arvalid_r && !rst;

    // nonsecure data access. the slave ignores prot, but driving something
    // non-zero means a slave that accidentally decoded it would break here
    assign m_axi_awprot = 3'b010;
    assign m_axi_arprot = 3'b010;
    assign m_axi_wstrb  = 4'hf;   // every register write is a full word

    always_ff @(posedge clk) begin
        if (rst) begin
            bstate       <= B_IDLE;
            awvalid_r    <= 1'b0;
            wvalid_r     <= 1'b0;
            arvalid_r    <= 1'b0;
            m_axi_bready <= 1'b0;
            m_axi_rready <= 1'b0;
            m_axi_awaddr <= 6'h0;
            m_axi_araddr <= 6'h0;
            m_axi_wdata  <= 32'h0;
            bus_rdata    <= 32'h0;
            bus_done     <= 1'b0;
            resp_err     <= 1'b0;
        end else begin
            bus_done <= 1'b0;

            case (bstate)
                B_IDLE: begin
                    if (bus_req) begin
                        if (bus_we) begin
                            m_axi_awaddr <= bus_addr;
                            m_axi_wdata  <= bus_wdata;
                            awvalid_r    <= 1'b1;
                            wvalid_r     <= 1'b1;
                            bstate       <= B_W;
                        end else begin
                            m_axi_araddr <= bus_addr;
                            arvalid_r    <= 1'b1;
                            bstate       <= B_AR;
                        end
                    end
                end

                B_W: begin
                    // drop each VALID as its own READY comes back
                    if (awvalid_r && m_axi_awready) awvalid_r <= 1'b0;
                    if (wvalid_r  && m_axi_wready ) wvalid_r  <= 1'b0;
                    // both phases accepted, this cycle or earlier -> wait for B
                    if ((!awvalid_r || m_axi_awready) && (!wvalid_r || m_axi_wready)) begin
                        m_axi_bready <= 1'b1;
                        bstate       <= B_B;
                    end
                end

                B_B: begin
                    if (m_axi_bvalid) begin
                        if (m_axi_bresp != 2'b00) resp_err <= 1'b1;
                        m_axi_bready <= 1'b0;
                        bus_done     <= 1'b1;
                        bstate       <= B_IDLE;
                    end
                end

                B_AR: begin
                    if (m_axi_arready) begin
                        arvalid_r    <= 1'b0;
                        m_axi_rready <= 1'b1;
                        bstate       <= B_R;
                    end
                end

                B_R: begin
                    if (m_axi_rvalid) begin
                        if (m_axi_rresp != 2'b00) resp_err <= 1'b1;
                        bus_rdata    <= m_axi_rdata;
                        m_axi_rready <= 1'b0;
                        bus_done     <= 1'b1;
                        bstate       <= B_IDLE;
                    end
                end

                default: bstate <= B_IDLE;
            endcase
        end
    end

    // ---- command fsm ----

    typedef enum logic [3:0] {
        C_CMD,                  // waiting for a command byte
        C_ARG,                  // collecting the 16 payload bytes
        C_WR,   C_WR_W,         // KEY0-3 or DIN0-3
        C_CHK,  C_CHK_W,        // is a key actually loaded (encrypt only)
        C_CTRL, C_CTRL_W,       // the KEY_LOAD / START pulse
        C_POLL, C_POLL_W,       // read STATUS until the bit we want is set
        C_RD,   C_RD_W,         // DOUT0-3
        C_TX,   C_TX_W          // shift the answer out a byte at a time
    } cstate_e;
    cstate_e cs;

    logic         is_key;       // this command is 'K' (vs 'E')
    logic         is_stat;      // this command is 'S'
    logic [127:0] abuf;         // the 16 bytes coming in
    logic [127:0] obuf;         // the bytes going back out
    logic [3:0]   argcnt;
    logic [1:0]   widx;         // which of the 4 words
    logic [4:0]   tidx;         // which byte going out
    logic [4:0]   tx_last;      // 15 for a ciphertext, 0 for a status byte

    always_ff @(posedge clk) begin
        if (rst) begin
            cs        <= C_CMD;
            is_key    <= 1'b0;
            is_stat   <= 1'b0;
            abuf      <= 128'h0;
            obuf      <= 128'h0;
            argcnt    <= 4'd0;
            widx      <= 2'd0;
            tidx      <= 5'd0;
            tx_last   <= 5'd0;
            bus_req   <= 1'b0;
            bus_we    <= 1'b0;
            bus_addr  <= 6'h0;
            bus_wdata <= 32'h0;
            tx_data   <= 8'h0;
            tx_send   <= 1'b0;
            status_o  <= 8'h0;
            overrun   <= 1'b0;
            cmd_err   <= 1'b0;
        end else begin
            bus_req <= 1'b0;    // defaults, so both come out as one cycle pulses
            tx_send <= 1'b0;

            // a byte that turns up anywhere except the two states listening
            // for one has nowhere to go. latch it so the board can show it
            // instead of the host quietly getting a wrong answer.
            if (rx_valid && cs != C_CMD && cs != C_ARG)
                overrun <= 1'b1;

            case (cs)
                C_CMD: begin
                    if (rx_valid) begin
                        argcnt <= 4'd0;
                        case (rx_data)
                            CMD_KEY: begin
                                is_key  <= 1'b1;
                                is_stat <= 1'b0;
                                cs      <= C_ARG;
                            end
                            CMD_ENC: begin
                                is_key  <= 1'b0;
                                is_stat <= 1'b0;
                                cs      <= C_ARG;
                            end
                            CMD_STATUS: begin
                                is_stat  <= 1'b1;
                                bus_we   <= 1'b0;
                                bus_addr <= R_STATUS;
                                bus_req  <= 1'b1;
                                cs       <= C_POLL_W;
                            end
                            default: ;   // not a command, drop it and stay put
                        endcase
                    end
                end

                C_ARG: begin
                    if (rx_valid) begin
                        abuf <= {abuf[119:0], rx_data};   // first byte ends up msb
                        if (argcnt == 4'd15) begin
                            widx <= 2'd0;
                            cs   <= C_WR;
                        end else begin
                            argcnt <= argcnt + 4'd1;
                        end
                    end
                end

                // KEY0-3 / DIN0-3. widx 0 is the msb word, which is what the
                // register map calls KEY0 - see its word order section.
                C_WR: begin
                    bus_we    <= 1'b1;
                    bus_addr  <= (is_key ? R_KEY0 : R_DIN0) + {2'b00, widx, 2'b00};
                    bus_wdata <= abuf[127 - 32*widx -: 32];
                    bus_req   <= 1'b1;
                    cs        <= C_WR_W;
                end

                C_WR_W: begin
                    if (bus_done) begin
                        // 'K' goes straight to the pulse; 'E' has to make sure
                        // there is a key first, see C_CHK
                        if (widx == 2'd3) cs <= is_key ? C_CTRL : C_CHK;
                        else begin
                            widx <= widx + 2'd1;
                            cs   <= C_WR;
                        end
                    end
                end

                // START is dropped by the wrapper unless KEY_READY is set,
                // and then STATUS.DONE never comes and the poll below spins
                // forever - the board wedges with all three status leds dark
                // and only the reset button gets it back. That is a real way
                // to lose a demo, so check first: no key, no encryption, drop
                // the command and light cmd_err. The host sees its read for 16
                // bytes time out, which is a much better failure than a board
                // that has stopped answering at all.
                //
                // This is the wrapper's own documented rule ("START is ignored
                // unless KEY_READY is high") enforced one level up, where
                // something can actually be done about it.
                C_CHK: begin
                    bus_we   <= 1'b0;
                    bus_addr <= R_STATUS;
                    bus_req  <= 1'b1;
                    cs       <= C_CHK_W;
                end

                C_CHK_W: begin
                    if (bus_done) begin
                        status_o <= bus_rdata[7:0];
                        if (bus_rdata[ST_KEY_READY]) begin
                            cs <= C_CTRL;
                        end else begin
                            cmd_err <= 1'b1;
                            cs      <= C_CMD;
                        end
                    end
                end

                C_CTRL: begin
                    bus_we    <= 1'b1;
                    bus_addr  <= R_CTRL;
                    bus_wdata <= is_key ? CTRL_KEY_LOAD : CTRL_START;
                    bus_req   <= 1'b1;
                    cs        <= C_CTRL_W;
                end

                C_CTRL_W: begin
                    if (bus_done) cs <= C_POLL;
                end

                C_POLL: begin
                    bus_we   <= 1'b0;
                    bus_addr <= R_STATUS;
                    bus_req  <= 1'b1;
                    cs       <= C_POLL_W;
                end

                C_POLL_W: begin
                    if (bus_done) begin
                        status_o <= bus_rdata[7:0];   // for the leds
                        if (is_stat) begin
                            // 'S' is a single read, answer with the low byte
                            obuf    <= {bus_rdata[7:0], 120'h0};
                            tidx    <= 5'd0;
                            tx_last <= 5'd0;
                            cs      <= C_TX;
                        end else if (is_key) begin
                            if (bus_rdata[ST_KEY_READY]) cs <= C_CMD;   // 'K' is silent
                            else                         cs <= C_POLL;
                        end else begin
                            if (bus_rdata[ST_DONE]) begin
                                widx <= 2'd0;
                                cs   <= C_RD;
                            end else begin
                                cs <= C_POLL;
                            end
                        end
                    end
                end

                C_RD: begin
                    bus_we   <= 1'b0;
                    bus_addr <= R_DOUT0 + {2'b00, widx, 2'b00};
                    bus_req  <= 1'b1;
                    cs       <= C_RD_W;
                end

                C_RD_W: begin
                    if (bus_done) begin
                        obuf[127 - 32*widx -: 32] <= bus_rdata;
                        if (widx == 2'd3) begin
                            tidx    <= 5'd0;
                            tx_last <= 5'd15;
                            cs      <= C_TX;
                        end else begin
                            widx <= widx + 2'd1;
                            cs   <= C_RD;
                        end
                    end
                end

                // msb byte first, same convention as the input side
                C_TX: begin
                    if (!tx_busy) begin
                        tx_data <= obuf[127 - 8*tidx -: 8];
                        tx_send <= 1'b1;
                        cs      <= C_TX_W;
                    end
                end

                // one dead cycle so tx_busy has had an edge to go high on,
                // then either queue the next byte or we are done. going back
                // to C_CMD while the last byte is still on the wire is fine -
                // the host cannot have answered it yet, and if it does send
                // early the byte gets taken instead of dropped.
                C_TX_W: begin
                    if (tidx == tx_last) begin
                        cs <= C_CMD;
                    end else begin
                        tidx <= tidx + 5'd1;
                        cs   <= C_TX;
                    end
                end

                default: cs <= C_CMD;
            endcase
        end
    end

endmodule
