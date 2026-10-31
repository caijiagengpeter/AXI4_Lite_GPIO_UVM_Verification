`timescale 1ns/1ps
`default_nettype none

module tb_bad_slave_top;
  import uvm_pkg::*;
  import axi4l_bad_slave_test_pkg::*;
  logic clk;
  axi4l_bad_slave_if bad_vif(clk);
  axi4l_bad_slave_checker checker(bad_vif);

  initial begin
    clk = 0;
    forever #5ns clk = ~clk;
  end

  initial begin
    uvm_config_db#(virtual axi4l_bad_slave_if)::set(
      null, "*", "bad_vif", bad_vif);
    run_test();
  end

  initial begin
    #100us;
    $fatal(1, "Global timeout: bad-slave selftest did not finish");
  end
endmodule

`default_nettype wire
