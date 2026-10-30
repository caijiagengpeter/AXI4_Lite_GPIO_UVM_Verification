class axi4l_gpio_v2_base_test extends uvm_test;
  `uvm_component_utils(axi4l_gpio_v2_base_test)

  axi4l_gpio_env env;

  function new(string name = "axi4l_gpio_v2_base_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(uvm_active_passive_enum)::set(
      this, "env.axi4l_agent", "is_active", UVM_ACTIVE);
    uvm_config_db#(uvm_active_passive_enum)::set(
      this, "env.gpio_agent", "is_active", UVM_ACTIVE);
    // Match the implemented RTL behavior for the open MASK-polarity issue.
    uvm_config_db#(bit)::set(this, "env.scoreboard",
                             "mask_one_enable", 1'b1);
    env = axi4l_gpio_env::type_id::create("env", this);
  endfunction

  task automatic axi_write(bit [AXI4L_ADDR_WIDTH-1:0] addr,
                           bit [AXI4L_DATA_WIDTH-1:0] data,
                           bit [AXI4L_DATA_WIDTH/8-1:0] strb = '1,
                           int unsigned aw_delay = 0,
                           int unsigned w_delay = 0,
                           int unsigned response_delay = 1);
    axi4l_single_access_seq seq;
    seq = axi4l_single_access_seq::type_id::create("write_seq");
    seq.access         = AXI4L_WRITE;
    seq.addr           = addr;
    seq.data           = data;
    seq.strb           = strb;
    seq.aw_delay       = aw_delay;
    seq.w_delay        = w_delay;
    seq.response_delay = response_delay;
    seq.start(env.axi_agent.sequencer);
  endtask

  task automatic axi_read(bit [AXI4L_ADDR_WIDTH-1:0] addr,
                          int unsigned ar_delay = 0,
                          int unsigned response_delay = 1);
    axi4l_single_access_seq seq;
    seq = axi4l_single_access_seq::type_id::create("read_seq");
    seq.access         = AXI4L_READ;
    seq.addr           = addr;
    seq.ar_delay       = ar_delay;
    seq.response_delay = response_delay;
    seq.start(env.axi_agent.sequencer);
  endtask

  task automatic gpio_level(bit [GPIO_NIN-1:0] value,
                            int unsigned hold_cycles);
    gpio_single_level_seq seq;
    seq = gpio_single_level_seq::type_id::create("gpio_level_seq");
    seq.value       = value;
    seq.hold_cycles = hold_cycles;
    seq.start(env.gpio_agent_h.sequencer);
  endtask
endclass
