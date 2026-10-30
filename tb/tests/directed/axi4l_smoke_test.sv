class axi4l_smoke_seq extends uvm_sequence #(axi4l_seq_item);
  `uvm_object_utils(axi4l_smoke_seq)

  function new(string name = "axi4l_smoke_seq");
    super.new(name);
  endfunction

  task automatic send_write(string item_name,
                            bit [AXI4L_ADDR_WIDTH-1:0] addr,
                            bit [AXI4L_DATA_WIDTH-1:0] data,
                            bit [AXI4L_DATA_WIDTH/8-1:0] strb = '1,
                            int unsigned aw_delay = 0,
                            int unsigned w_delay = 0);
    axi4l_seq_item tr;

    tr = axi4l_seq_item::type_id::create(item_name);
    start_item(tr);
    tr.access       = AXI4L_WRITE;
    tr.addr         = addr;
    tr.data         = data;
    tr.strb         = strb;
    tr.prot         = 3'b000;
    tr.aw_delay     = aw_delay;
    tr.w_delay      = w_delay;
    tr.bready_delay = 1;
    finish_item(tr);
  endtask

  task automatic send_read(string item_name,
                           bit [AXI4L_ADDR_WIDTH-1:0] addr);
    axi4l_seq_item tr;

    tr = axi4l_seq_item::type_id::create(item_name);
    start_item(tr);
    tr.access       = AXI4L_READ;
    tr.addr         = addr;
    tr.prot         = 3'b000;
    tr.ar_delay     = 0;
    tr.rready_delay = 1;
    finish_item(tr);
  endtask

  task body();
    // The scoreboard owns response, read-data, and GPIO checking.  This
    // sequence only describes useful directed stimulus.
    send_write("load_3",   5'h00, 32'h0000_0003, 4'b1111, 0, 2);
    send_read ("read_3",   5'h00);

    send_write("set_4",    5'h04, 32'h0000_0004);
    send_read ("read_7",   5'h04);

    send_write("clear_1",  5'h08, 32'h0000_0001);
    send_read ("read_6",   5'h08);

    send_write("toggle_3", 5'h0c, 32'h0000_0003);
    send_read ("read_5",   5'h0c);

    send_write("load_pattern", 5'h00, 32'h1122_3344);
    send_read ("read_pattern", 5'h00);

    // Byte lanes 0 and 2 are replaced: 0x11223344 -> 0x11BB33DD.
    // This value already has zero in [31:30], so NOUT=30 does not alter it.
    send_write("partial_load", 5'h00, 32'hAABB_CCDD, 4'b0101);

    // All four output-register read aliases must expose the same state.
    send_read("read_alias_load",   5'h00);
    send_read("read_alias_set",    5'h04);
    send_read("read_alias_clear",  5'h08);
    send_read("read_alias_toggle", 5'h0c);

    `uvm_info("SMOKE_PASS",
              "AXI directed smoke completed; scoreboard owns data pass/fail",
              UVM_NONE)
  endtask
endclass

class axi4l_smoke_test extends uvm_test;
  `uvm_component_utils(axi4l_smoke_test)

  axi4l_gpio_env env;

  function new(string name = "axi4l_smoke_test", uvm_component parent = null);
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
    axi4l_smoke_seq seq;

    phase.raise_objection(this);
    seq = axi4l_smoke_seq::type_id::create("seq");
    seq.start(env.axi_agent.sequencer);
    phase.drop_objection(this);
  endtask
endclass

