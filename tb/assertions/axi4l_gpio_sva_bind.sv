`timescale 1ns/1ps
`default_nettype none

bind axilgpio axi4l_gpio_sva #(
  .ADDR_WIDTH    (C_AXI_ADDR_WIDTH),
  .DATA_WIDTH    (C_AXI_DATA_WIDTH),
  .NOUT          (NOUT),
  .NIN           (NIN),
  .DEFAULT_OUTPUT(DEFAULT_OUTPUT)
) axi4l_gpio_sva_i (
  .clk            (S_AXI_ACLK),
  .reset_n        (S_AXI_ARESETN),
  .awaddr         (S_AXI_AWADDR),
  .awprot         (S_AXI_AWPROT),
  .awvalid        (S_AXI_AWVALID),
  .awready        (S_AXI_AWREADY),
  .wdata          (S_AXI_WDATA),
  .wstrb          (S_AXI_WSTRB),
  .wvalid         (S_AXI_WVALID),
  .wready         (S_AXI_WREADY),
  .bresp          (S_AXI_BRESP),
  .bvalid         (S_AXI_BVALID),
  .bready         (S_AXI_BREADY),
  .araddr         (S_AXI_ARADDR),
  .arprot         (S_AXI_ARPROT),
  .arvalid        (S_AXI_ARVALID),
  .arready        (S_AXI_ARREADY),
  .rdata          (S_AXI_RDATA),
  .rresp          (S_AXI_RRESP),
  .rvalid         (S_AXI_RVALID),
  .rready         (S_AXI_RREADY),
  .i_gpio         (i_gpio[NIN-1:0]),
  .o_gpio         (o_gpio),
  .o_int          (o_int),
  .write_accept   (axil_write_ready),
  .write_word_addr(awskd_addr[2:0]),
  .write_data     (wskd_data),
  .write_strb     (wskd_strb),
  .read_accept    (axil_read_ready),
  .q_gpio         (INPUT_HANDLING.q_gpio),
  .qq_gpio        (INPUT_HANDLING.qq_gpio),
  .last_gpio      (INPUT_HANDLING.last_gpio),
  .changed        (INPUT_HANDLING.toggled),
  .mask           (INPUT_HANDLING.r_mask)
);

`default_nettype wire
