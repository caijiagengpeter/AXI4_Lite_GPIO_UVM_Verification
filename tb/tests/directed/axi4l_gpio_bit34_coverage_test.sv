class axi4l_gpio_bit34_coverage_test extends axi4l_gpio_v2_base_test;
  `uvm_component_utils(axi4l_gpio_bit34_coverage_test)

  function new(string name = "axi4l_gpio_bit34_coverage_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    // Keep each external level stable long enough to traverse the q/qq/last
    // synchronizer pipeline.  Readbacks retain normal scoreboard checking.
    gpio_level(5'b00000, 6);

    gpio_level(5'b01000, 6); // bit3 synchronized rise
    axi_read(5'h10);         // INPUT: bit3 high
    axi_read(5'h14);         // CHANGED: bit3 sticky set

    gpio_level(5'b00000, 6); // bit3 synchronized fall
    axi_read(5'h10);
    axi_read(5'h14);         // CHANGED: bit3 remains set

    gpio_level(5'b10000, 6); // bit4 synchronized rise
    axi_read(5'h10);         // INPUT: bit4 high
    axi_read(5'h14);         // CHANGED: bits3/4 sticky set

    gpio_level(5'b00000, 6); // bit4 synchronized fall
    axi_read(5'h10);
    axi_read(5'h14);         // CHANGED: bits3/4 remain set

    `uvm_info("BIT34_COVERAGE_DONE",
              "GPIO bit3/bit4 synchronized rise/fall scenario completed",
              UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
