class axi4l_request_stall_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_request_stall_test)

  localparam bit [AXI4L_ADDR_WIDTH-1:0] ADDR_LOAD  = 5'h00;
  localparam bit [AXI4L_ADDR_WIDTH-1:0] ADDR_INPUT = 5'h10;
  localparam int unsigned RESPONSE_HOLD_CYCLES = 12;

  function new(string name = "axi4l_request_stall_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    // Only this closure test retires sequence items at request acceptance.
    // Every existing test keeps the driver's original blocking behavior.
    uvm_config_db#(bit)::set(this, "env.axi4l_agent.driver",
                             "limited_overlap_mode", 1'b1);
    super.build_phase(phase);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    // The DUT has one AW skid entry and one W skid entry.  While write #1's
    // B response is held, write #2 is legally accepted into those entries.
    // Write #3 must then hold AWVALID/WVALID and stable payload until BREADY
    // releases write #1 and the buffered request can advance.  ADDR_INPUT is
    // read-only, so this protocol test does not add register side effects.
    axi_write(ADDR_INPUT, 32'h1111_1111, 4'hf,
              0, 0, RESPONSE_HOLD_CYCLES);
    axi_write(ADDR_INPUT, 32'h2222_2222, 4'hf, 0, 0, 0);
    axi_write(ADDR_INPUT, 32'h3333_3333, 4'hf, 0, 0, 0);
    env.axi_agent.driver.wait_for_limited_idle();

    // The read channel has the same one-entry skid behavior.  Read #2 fills
    // it while read #1's R response is held; read #3 then stalls with a stable
    // AR payload.  LOAD is stable because the writes above were read-only.
    axi_read(ADDR_LOAD, 0, RESPONSE_HOLD_CYCLES);
    axi_read(ADDR_LOAD, 0, 0);
    axi_read(ADDR_LOAD, 0, 0);
    env.axi_agent.driver.wait_for_limited_idle();

    // Give both monitors one final sampling edge before ending the test.
    repeat (2) @(env.axi_agent.driver.vif.drv_cb);
    `uvm_info("REQUEST_STALL_DONE",
              "deterministic AW/W/AR request-side stall scenario completed",
              UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
