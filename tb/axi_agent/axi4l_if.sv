`timescale 1ns/1ps

interface axi4l_if #(
  parameter int ADDR_WIDTH = 5,
  parameter int DATA_WIDTH = 32
) (
  input logic ACLK
);

  localparam int STRB_WIDTH = DATA_WIDTH / 8;

  logic                  ARESETN;

  logic [ADDR_WIDTH-1:0] AWADDR;
  logic [2:0]            AWPROT;
  logic                  AWVALID;
  logic                  AWREADY;

  logic [DATA_WIDTH-1:0] WDATA;
  logic [STRB_WIDTH-1:0] WSTRB;
  logic                  WVALID;
  logic                  WREADY;

  logic [1:0]            BRESP;
  logic                  BVALID;
  logic                  BREADY;

  logic [ADDR_WIDTH-1:0] ARADDR;
  logic [2:0]            ARPROT;
  logic                  ARVALID;
  logic                  ARREADY;

  logic [DATA_WIDTH-1:0] RDATA;
  logic [1:0]            RRESP;
  logic                  RVALID;
  logic                  RREADY;

  // Optional directed-slave observability.  Production DUT tests ignore
  // these fields; the v4 component tests use them to prove actual accepted
  // outstanding depth rather than merely reporting Driver credit settings.
  logic [31:0]           test_max_write_outstanding;
  logic [31:0]           test_max_read_outstanding;

  // The driver changes master outputs just after an edge and samples DUT
  // outputs just before an edge.  This avoids testbench/DUT race conditions.
  clocking drv_cb @(posedge ACLK);
    default input #1step output #1step;
    input  ARESETN;
    output AWADDR, AWPROT, AWVALID;
    input  AWREADY;
    output WDATA, WSTRB, WVALID;
    input  WREADY;
    input  BRESP, BVALID;
    output BREADY;
    output ARADDR, ARPROT, ARVALID;
    input  ARREADY;
    input  RDATA, RRESP, RVALID;
    output RREADY;
  endclocking

  clocking mon_cb @(posedge ACLK);
    default input #1step;
    input ARESETN;
    input AWADDR, AWPROT, AWVALID, AWREADY;
    input WDATA, WSTRB, WVALID, WREADY;
    input BRESP, BVALID, BREADY;
    input ARADDR, ARPROT, ARVALID, ARREADY;
    input RDATA, RRESP, RVALID, RREADY;
  endclocking

  modport driver_mp  (clocking drv_cb);
  modport monitor_mp (clocking mon_cb);

  // Signal directions as seen by an AXI master.
  modport master_mp (
    input  ACLK, ARESETN,
    output AWADDR, AWPROT, AWVALID,
    input  AWREADY,
    output WDATA, WSTRB, WVALID,
    input  WREADY,
    input  BRESP, BVALID,
    output BREADY,
    output ARADDR, ARPROT, ARVALID,
    input  ARREADY,
    input  RDATA, RRESP, RVALID,
    output RREADY
  );

endinterface

