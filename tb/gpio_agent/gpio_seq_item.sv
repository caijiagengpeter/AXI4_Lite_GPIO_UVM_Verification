class gpio_seq_item extends uvm_sequence_item;
  rand bit [GPIO_NIN-1:0] value;
  rand int unsigned       hold_cycles;

  constraint hold_cycles_c {
    hold_cycles inside {[1:20]};
  }

  `uvm_object_utils_begin(gpio_seq_item)
    `uvm_field_int(value,       UVM_BIN)
    `uvm_field_int(hold_cycles, UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "gpio_seq_item");
    super.new(name);
  endfunction
endclass
