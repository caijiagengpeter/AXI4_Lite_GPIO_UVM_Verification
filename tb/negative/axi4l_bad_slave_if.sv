`timescale 1ns/1ps

interface axi4l_bad_slave_if(input logic ACLK);
  logic ARESETN;
  logic [4:0] AWADDR;
  logic [2:0] AWPROT;
  logic AWVALID, AWREADY;
  logic [31:0] WDATA;
  logic [3:0] WSTRB;
  logic WVALID, WREADY;
  logic [1:0] BRESP;
  logic BVALID, BREADY;
  logic [4:0] ARADDR;
  logic [2:0] ARPROT;
  logic ARVALID, ARREADY;
  logic [31:0] RDATA;
  logic [1:0] RRESP;
  logic RVALID, RREADY;
  logic audit_pending;
  logic clear_faults;
  logic [7:0] detected_faults;

  clocking drv_cb @(posedge ACLK);
    default input #1step output #1step;
    output ARESETN, AWADDR, AWPROT, AWVALID, AWREADY;
    output WDATA, WSTRB, WVALID, WREADY;
    output BRESP, BVALID, BREADY;
    output ARADDR, ARPROT, ARVALID, ARREADY;
    output RDATA, RRESP, RVALID, RREADY;
    output audit_pending, clear_faults;
    input detected_faults;
  endclocking
endinterface
