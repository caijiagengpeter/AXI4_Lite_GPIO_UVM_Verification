class gpio_single_level_seq extends uvm_sequence #(gpio_seq_item);
  `uvm_object_utils(gpio_single_level_seq)

  bit [GPIO_NIN-1:0] value;
  int unsigned       hold_cycles = 1;

  function new(string name = "gpio_single_level_seq");
    super.new(name);
  endfunction

  task body();
    gpio_seq_item tr;
    tr = gpio_seq_item::type_id::create("tr");
    start_item(tr);
    tr.value       = value;
    tr.hold_cycles = hold_cycles;
    finish_item(tr);
  endtask
endclass
