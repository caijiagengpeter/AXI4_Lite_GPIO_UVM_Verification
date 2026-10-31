`timescale 1ns/1ps
`default_nettype none

// Bus-only assertions used by the NIN=0 elaboration.  The full GPIO assertion
// module reaches into INPUT_HANDLING, which intentionally does not exist when
// NIN=0; this variant preserves the externally meaningful AXI checks without
// inventing zero-width internal signals.
module axi4l_protocol_sva #(
  parameter int ADDR_WIDTH = 5,
  parameter int DATA_WIDTH = 32
) (
  input wire clk,
  input wire reset_n,
  input wire [ADDR_WIDTH-1:0] awaddr,
  input wire [2:0] awprot,
  input wire awvalid,
  input wire awready,
  input wire [DATA_WIDTH-1:0] wdata,
  input wire [DATA_WIDTH/8-1:0] wstrb,
  input wire wvalid,
  input wire wready,
  input wire [1:0] bresp,
  input wire bvalid,
  input wire bready,
  input wire [ADDR_WIDTH-1:0] araddr,
  input wire [2:0] arprot,
  input wire arvalid,
  input wire arready,
  input wire [DATA_WIDTH-1:0] rdata,
  input wire [1:0] rresp,
  input wire rvalid,
  input wire rready,
  input wire write_accept,
  input wire read_accept
);
  a_aw_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      awvalid && !awready |=> awvalid && $stable({awaddr, awprot}));
  a_w_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      wvalid && !wready |=> wvalid && $stable({wdata, wstrb}));
  a_ar_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      arvalid && !arready |=> arvalid && $stable({araddr, arprot}));
  a_b_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      bvalid && !bready |=> bvalid && $stable(bresp));
  a_r_stable_while_stalled: assert property (
    @(posedge clk) disable iff (!reset_n)
      rvalid && !rready |=> rvalid && $stable({rdata, rresp}));
  a_write_accept_sets_bvalid: assert property (
    @(posedge clk) disable iff (!reset_n) write_accept |=> bvalid);
  a_read_accept_sets_rvalid: assert property (
    @(posedge clk) disable iff (!reset_n) read_accept |=> rvalid);
  a_bvalid_rise_has_write: assert property (
    @(posedge clk) disable iff (!reset_n) $rose(bvalid) |-> $past(write_accept));
  a_rvalid_rise_has_read: assert property (
    @(posedge clk) disable iff (!reset_n) $rose(rvalid) |-> $past(read_accept));
  a_bresp_is_okay: assert property (
    @(posedge clk) disable iff (!reset_n) bvalid |-> bresp == 2'b00);
  a_rresp_is_okay: assert property (
    @(posedge clk) disable iff (!reset_n) rvalid |-> rresp == 2'b00);
endmodule

`default_nettype wire
