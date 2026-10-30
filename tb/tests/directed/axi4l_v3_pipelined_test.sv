class axi4l_v3_pipelined_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_v3_pipelined_test)

  function new(string name = "axi4l_v3_pipelined_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    // Legacy mode remains the project default.  This test explicitly selects
    // the reusable v3 path and permits three ordered B and R responses.
    uvm_config_db#(bit)::set(this, "env.axi4l_agent.driver",
                             "pipelined_mode", 1'b1);
    uvm_config_db#(int unsigned)::set(this, "env.axi4l_agent.driver",
                                      "max_write_outstanding", 3);
    uvm_config_db#(int unsigned)::set(this, "env.axi4l_agent.driver",
                                      "max_read_outstanding", 3);
    super.build_phase(phase);
  endfunction

  task run_phase(uvm_phase phase);
    axi4l_v3_pipeline_seq seq;
    phase.raise_objection(this);
    seq = axi4l_v3_pipeline_seq::type_id::create("seq");
    seq.start(env.axi_agent.sequencer);
    env.axi_agent.driver.wait_for_pipelined_idle();
    repeat (2) @(env.axi_agent.driver.vif.drv_cb);
    phase.drop_objection(this);
  endtask
endclass
