class gpio_agent_smoke_seq extends uvm_sequence #(gpio_seq_item);
  `uvm_object_utils(gpio_agent_smoke_seq)

  function new(string name = "gpio_agent_smoke_seq");
    super.new(name);
  endfunction

  task automatic send_level(string item_name,
                            bit [GPIO_NIN-1:0] value,
                            int unsigned hold_cycles);
    gpio_seq_item tr;

    tr = gpio_seq_item::type_id::create(item_name);
    start_item(tr);
    tr.value       = value;
    tr.hold_cycles = hold_cycles;
    finish_item(tr);
  endtask

  task body();
    send_level("gpio_zero_0", 5'b00000, 2);
    send_level("gpio_one",    5'b00001, 4);
    send_level("gpio_five",   5'b00101, 4);
    send_level("gpio_zero_1", 5'b00000, 2);

    `uvm_info("GPIO_SMOKE_PASS",
              "GPIO level/hold sequence completed through the active GPIO agent",
              UVM_NONE)
  endtask
endclass

class gpio_agent_smoke_test extends uvm_test;
  `uvm_component_utils(gpio_agent_smoke_test)

  axi4l_gpio_env env;

  function new(string name = "gpio_agent_smoke_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    uvm_config_db#(uvm_active_passive_enum)::set(
      this, "env.axi4l_agent", "is_active", UVM_ACTIVE);
    uvm_config_db#(uvm_active_passive_enum)::set(
      this, "env.gpio_agent", "is_active", UVM_ACTIVE);
    env = axi4l_gpio_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    gpio_agent_smoke_seq seq;

    phase.raise_objection(this);
    seq = gpio_agent_smoke_seq::type_id::create("seq");
    seq.start(env.gpio_agent_h.sequencer);
    phase.drop_objection(this);
  endtask
endclass
