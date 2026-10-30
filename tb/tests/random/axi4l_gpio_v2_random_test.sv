class axi4l_gpio_v2_random_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_gpio_v2_random_test)

  function new(string name = "axi4l_gpio_v2_random_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    bit [AXI4L_ADDR_WIDTH-1:0]   addr;
    bit [AXI4L_DATA_WIDTH-1:0]   data;
    bit [AXI4L_DATA_WIDTH/8-1:0] strb;
    int unsigned aw_delay;
    int unsigned w_delay;

    phase.raise_objection(this);
    gpio_level('0, 3);

    for (int unsigned index = 0; index < 64; index++) begin
      addr     = $urandom_range(0, 3) * 4;
      data     = $urandom();
      strb     = $urandom_range(0, 15);
      aw_delay = $urandom_range(0, 3);
      w_delay  = $urandom_range(0, 3);
      axi_write(addr, data, strb, aw_delay, w_delay,
                $urandom_range(0, 3));

      if ((index % 4) == 3)
        begin
          addr = $urandom_range(0, 3) * 4;
          axi_read(addr, $urandom_range(0, 2), $urandom_range(0, 3));
        end
    end

    gpio_level('0, 2);
    `uvm_info("V2_RANDOM_DONE",
              "V2 randomized output operation scenario completed",
              UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
