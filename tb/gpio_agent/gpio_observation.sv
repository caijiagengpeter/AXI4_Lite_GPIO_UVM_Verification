class gpio_observation extends uvm_sequence_item;
  logic                     reset_n;
  logic [GPIO_NIN-1:0]      i_gpio;
  logic [GPIO_NOUT-1:0]     o_gpio;
  logic                     o_int;
  longint unsigned          sample_cycle;

  `uvm_object_utils_begin(gpio_observation)
    `uvm_field_int(reset_n, UVM_DEFAULT)
    `uvm_field_int(i_gpio,  UVM_BIN)
    `uvm_field_int(o_gpio,  UVM_HEX)
    `uvm_field_int(o_int,   UVM_DEFAULT)
    `uvm_field_int(sample_cycle, UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "gpio_observation");
    super.new(name);
  endfunction
endclass
