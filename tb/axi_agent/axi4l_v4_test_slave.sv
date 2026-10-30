`timescale 1ns/1ps

module axi4l_v4_test_slave #(
  parameter int ADDR_WIDTH = 5,
  parameter int DATA_WIDTH = 32,
  parameter int MAX_DEPTH  = 8
) (
  input  logic                  ACLK,
  input  logic                  ARESETN,
  input  logic [ADDR_WIDTH-1:0] AWADDR,
  input  logic [2:0]            AWPROT,
  input  logic                  AWVALID,
  output logic                  AWREADY,
  input  logic [DATA_WIDTH-1:0] WDATA,
  input  logic [DATA_WIDTH/8-1:0] WSTRB,
  input  logic                  WVALID,
  output logic                  WREADY,
  output logic [1:0]            BRESP,
  output logic                  BVALID,
  input  logic                  BREADY,
  input  logic [ADDR_WIDTH-1:0] ARADDR,
  input  logic [2:0]            ARPROT,
  input  logic                  ARVALID,
  output logic                  ARREADY,
  output logic [DATA_WIDTH-1:0] RDATA,
  output logic [1:0]            RRESP,
  output logic                  RVALID,
  input  logic                  RREADY,
  output logic [31:0]           max_write_outstanding,
  output logic [31:0]           max_read_outstanding
);
  typedef struct packed {
    logic [ADDR_WIDTH-1:0] addr;
    logic [2:0]            prot;
  } aw_entry_t;
  typedef struct packed {
    logic [DATA_WIDTH-1:0] data;
    logic [DATA_WIDTH/8-1:0] strb;
  } w_entry_t;

  aw_entry_t aw_q[$];
  w_entry_t  w_q[$];
  logic [DATA_WIDTH-1:0] r_q[$];
  bit b_q[$];
  int unsigned depth_cfg;
  int unsigned cycle_count;
  int unsigned aw_unanswered;
  int unsigned w_unanswered;
  int unsigned ar_unanswered;

  function automatic logic [DATA_WIDTH-1:0]
    read_value(input logic [ADDR_WIDTH-1:0] addr);
    read_value = {{(DATA_WIDTH-ADDR_WIDTH){1'b0}}, addr} ^ 32'h5a5a_1000;
  endfunction

  initial begin
    depth_cfg = MAX_DEPTH;
    void'($value$plusargs("V4_SLAVE_DEPTH=%d", depth_cfg));
    if ((depth_cfg == 0) || (depth_cfg > MAX_DEPTH))
      $fatal(1, "V4_SLAVE_DEPTH must be in 1..%0d", MAX_DEPTH);
  end

  always_comb begin
    // Independent deterministic stalls exercise VALID/payload stability.
    AWREADY = ARESETN && (aw_unanswered < depth_cfg) &&
              ((cycle_count % 5) != 1);
    WREADY  = ARESETN && (w_unanswered < depth_cfg) &&
              ((cycle_count % 7) != 2);
    ARREADY = ARESETN && (ar_unanswered < depth_cfg) &&
              ((cycle_count % 6) != 3);
  end

  always @(posedge ACLK) begin : slave_state
    aw_entry_t aw_entry;
    w_entry_t  w_entry;
    int unsigned write_pending;
    int unsigned read_pending;

    if (!ARESETN) begin
      aw_q.delete();
      w_q.delete();
      r_q.delete();
      b_q.delete();
      cycle_count = 0;
      aw_unanswered = 0;
      w_unanswered = 0;
      ar_unanswered = 0;
      BVALID = 1'b0;
      BRESP  = 2'b00;
      RVALID = 1'b0;
      RRESP  = 2'b00;
      RDATA  = '0;
      max_write_outstanding = 0;
      max_read_outstanding  = 0;
    end else begin
      cycle_count++;

      if (AWVALID && AWREADY) begin
        aw_entry.addr = AWADDR;
        aw_entry.prot = AWPROT;
        aw_q.push_back(aw_entry);
        aw_unanswered++;
      end
      if (WVALID && WREADY) begin
        w_entry.data = WDATA;
        w_entry.strb = WSTRB;
        w_q.push_back(w_entry);
        w_unanswered++;
      end
      if (ARVALID && ARREADY) begin
        r_q.push_back(read_value(ARADDR));
        ar_unanswered++;
      end

      // Pair by channel FIFO order; no transaction IDs exist on AXI4-Lite.
      while ((aw_q.size() != 0) && (w_q.size() != 0)) begin
        aw_entry = aw_q.pop_front();
        w_entry  = w_q.pop_front();
        b_q.push_back(1'b1);
      end

      if (BVALID && BREADY) begin
        BVALID = 1'b0;
        aw_unanswered--;
        w_unanswered--;
      end
      if (!BVALID && (b_q.size() != 0)) begin
        void'(b_q.pop_front());
        BRESP  = 2'b00;
        BVALID = 1'b1;
      end

      if (RVALID && RREADY) begin
        RVALID = 1'b0;
        ar_unanswered--;
      end
      if (!RVALID && (r_q.size() != 0)) begin
        RDATA  = r_q.pop_front();
        RRESP  = 2'b00;
        RVALID = 1'b1;
      end

      write_pending = (aw_unanswered < w_unanswered)
                    ? aw_unanswered : w_unanswered;
      read_pending = ar_unanswered;
      if (write_pending > max_write_outstanding)
        max_write_outstanding = write_pending;
      if (read_pending > max_read_outstanding)
        max_read_outstanding = read_pending;
    end
  end
endmodule
