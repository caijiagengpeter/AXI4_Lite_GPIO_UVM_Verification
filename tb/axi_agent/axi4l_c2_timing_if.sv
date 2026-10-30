`timescale 1ns/1ps

// Read-only C2 adapter surface.  tb_top drives these nets only from the two
// real DUT execution predicates; no DUT data/state is exported here.
interface axi4l_c2_timing_if(input logic ACLK);
  logic ARESETN;
  logic WRITE_COMMIT;
  logic READ_SNAPSHOT;

  clocking mon_cb @(posedge ACLK);
    default input #1step;
    input ARESETN, WRITE_COMMIT, READ_SNAPSHOT;
  endclocking

  modport monitor_mp (clocking mon_cb);
endinterface
