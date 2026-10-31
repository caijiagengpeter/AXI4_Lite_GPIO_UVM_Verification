package axi4l_bad_slave_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  class axi4l_bad_slave_selftest extends uvm_test;
    `uvm_component_utils(axi4l_bad_slave_selftest)
    virtual axi4l_bad_slave_if vif;

    localparam bit [7:0] F_EARLY_B       = 8'h01;
    localparam bit [7:0] F_EARLY_R       = 8'h02;
    localparam bit [7:0] F_R_STABILITY   = 8'h04;
    localparam bit [7:0] F_B_STABILITY   = 8'h08;
    localparam bit [7:0] F_REQ_STABILITY = 8'h10;
    localparam bit [7:0] F_STALE_RESET   = 8'h20;
    localparam bit [7:0] F_DUPLICATE     = 8'h40;
    localparam bit [7:0] F_MISSING       = 8'h80;

    function new(string name = "axi4l_bad_slave_selftest",
                 uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi4l_bad_slave_if)::get(
            this, "", "bad_vif", vif))
        `uvm_fatal("BAD_NOVIF", "bad-slave selftest did not receive vif")
    endfunction

    task automatic idle_bus();
      vif.drv_cb.AWADDR <= '0; vif.drv_cb.AWPROT <= '0;
      vif.drv_cb.AWVALID <= 0; vif.drv_cb.AWREADY <= 0;
      vif.drv_cb.WDATA <= '0; vif.drv_cb.WSTRB <= '0;
      vif.drv_cb.WVALID <= 0; vif.drv_cb.WREADY <= 0;
      vif.drv_cb.BRESP <= '0; vif.drv_cb.BVALID <= 0;
      vif.drv_cb.BREADY <= 0;
      vif.drv_cb.ARADDR <= '0; vif.drv_cb.ARPROT <= '0;
      vif.drv_cb.ARVALID <= 0; vif.drv_cb.ARREADY <= 0;
      vif.drv_cb.RDATA <= '0; vif.drv_cb.RRESP <= '0;
      vif.drv_cb.RVALID <= 0; vif.drv_cb.RREADY <= 0;
      vif.drv_cb.audit_pending <= 0;
    endtask

    task automatic reset_scenario();
      idle_bus();
      vif.drv_cb.clear_faults <= 1;
      vif.drv_cb.ARESETN <= 0;
      repeat (2) @(vif.drv_cb);
      vif.drv_cb.clear_faults <= 0;
      vif.drv_cb.ARESETN <= 1;
      repeat (2) @(vif.drv_cb);
    endtask

    task automatic expect_fault(bit [7:0] expected, string scenario);
      repeat (2) @(vif.drv_cb);
      if ((vif.drv_cb.detected_faults & expected) != expected)
        `uvm_error("BAD_SLAVE_MISSED",
          $sformatf("%s expected=0x%02h detected=0x%02h",
                    scenario, expected, vif.drv_cb.detected_faults))
      else
        `uvm_info("BAD_SLAVE_DETECTED",
          $sformatf("%s detected expected fault mask 0x%02h",
                    scenario, expected), UVM_NONE)
    endtask

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);

      reset_scenario();
      vif.drv_cb.BVALID <= 1; vif.drv_cb.BREADY <= 0;
      expect_fault(F_EARLY_B, "BVALID before AW/W");

      reset_scenario();
      vif.drv_cb.RVALID <= 1; vif.drv_cb.RREADY <= 0;
      expect_fault(F_EARLY_R, "RVALID before AR");

      reset_scenario();
      vif.drv_cb.ARVALID <= 1; vif.drv_cb.ARREADY <= 1;
      @(vif.drv_cb);
      vif.drv_cb.ARVALID <= 0; vif.drv_cb.ARREADY <= 0;
      vif.drv_cb.RVALID <= 1; vif.drv_cb.RREADY <= 0;
      vif.drv_cb.RDATA <= 32'h1111_1111; vif.drv_cb.RRESP <= 2'b00;
      @(vif.drv_cb);
      vif.drv_cb.RDATA <= 32'h2222_2222; vif.drv_cb.RRESP <= 2'b10;
      expect_fault(F_R_STABILITY, "RDATA/RRESP changed while stalled");

      reset_scenario();
      vif.drv_cb.AWVALID <= 1; vif.drv_cb.AWREADY <= 1;
      vif.drv_cb.WVALID <= 1; vif.drv_cb.WREADY <= 1;
      @(vif.drv_cb);
      vif.drv_cb.AWVALID <= 0; vif.drv_cb.WVALID <= 0;
      vif.drv_cb.AWREADY <= 0; vif.drv_cb.WREADY <= 0;
      vif.drv_cb.BVALID <= 1; vif.drv_cb.BREADY <= 0;
      vif.drv_cb.BRESP <= 2'b00;
      @(vif.drv_cb);
      vif.drv_cb.BRESP <= 2'b10;
      expect_fault(F_B_STABILITY, "BRESP changed while stalled");

      reset_scenario();
      vif.drv_cb.AWVALID <= 1; vif.drv_cb.AWREADY <= 0;
      vif.drv_cb.AWADDR <= 5'h04;
      vif.drv_cb.WVALID <= 1; vif.drv_cb.WREADY <= 0;
      vif.drv_cb.WDATA <= 32'haaaa_5555; vif.drv_cb.WSTRB <= 4'hf;
      @(vif.drv_cb);
      vif.drv_cb.AWADDR <= 5'h08;
      vif.drv_cb.WDATA <= 32'h5555_aaaa; vif.drv_cb.WSTRB <= 4'h3;
      expect_fault(F_REQ_STABILITY, "AW/W payload changed while stalled");

      reset_scenario();
      vif.drv_cb.ARVALID <= 1; vif.drv_cb.ARREADY <= 1;
      @(vif.drv_cb);
      vif.drv_cb.ARVALID <= 0; vif.drv_cb.ARREADY <= 0;
      vif.drv_cb.ARESETN <= 0;
      repeat (2) @(vif.drv_cb);
      vif.drv_cb.ARESETN <= 1;
      @(vif.drv_cb);
      vif.drv_cb.RVALID <= 1; vif.drv_cb.RREADY <= 0;
      expect_fault(F_STALE_RESET, "stale response after reset");

      reset_scenario();
      vif.drv_cb.AWVALID <= 1; vif.drv_cb.AWREADY <= 1;
      vif.drv_cb.WVALID <= 1; vif.drv_cb.WREADY <= 1;
      @(vif.drv_cb);
      vif.drv_cb.AWVALID <= 0; vif.drv_cb.WVALID <= 0;
      vif.drv_cb.AWREADY <= 0; vif.drv_cb.WREADY <= 0;
      vif.drv_cb.BVALID <= 1; vif.drv_cb.BREADY <= 1;
      @(vif.drv_cb);
      vif.drv_cb.BVALID <= 0;
      @(vif.drv_cb);
      vif.drv_cb.BVALID <= 1;
      expect_fault(F_DUPLICATE, "duplicate B response");

      reset_scenario();
      vif.drv_cb.ARVALID <= 1; vif.drv_cb.ARREADY <= 1;
      @(vif.drv_cb);
      vif.drv_cb.ARVALID <= 0; vif.drv_cb.ARREADY <= 0;
      vif.drv_cb.audit_pending <= 1;
      @(vif.drv_cb);
      vif.drv_cb.audit_pending <= 0;
      expect_fault(F_MISSING, "missing R response at audit");

      `uvm_info("C3_3_BAD_SLAVE_PASS",
        "eight controlled protocol faults were observed by the detector; BRESP=SLVERR alone was not classified as a violation",
        UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
