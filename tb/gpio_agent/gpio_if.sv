`timescale 1ns/1ps

interface gpio_if #(
  parameter int NIN  = 5,
  parameter int NOUT = 30
) (
  input  logic             ACLK,
  input  logic             ARESETN,
  output logic [NIN-1:0]   i_gpio,
  input  logic [NOUT-1:0]  o_gpio,
  input  logic             o_int
);

  // Only i_gpio is an output of the driver clocking block.  o_gpio and
  // o_int are DUT outputs and can never be driven through this interface.
  clocking drv_cb @(posedge ACLK);
    default input #1step output #1step;
    input  ARESETN;
    output i_gpio;
  endclocking

  // The monitor sees the complete external-pin view as inputs.
  clocking mon_cb @(posedge ACLK);
    default input #1step;
    input ARESETN;
    input i_gpio;
    input o_gpio;
    input o_int;
  endclocking

  modport driver_mp (
    clocking drv_cb
  );

  modport monitor_mp (
    clocking mon_cb
  );

endinterface
