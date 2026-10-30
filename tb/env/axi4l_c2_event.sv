typedef enum bit [1:0] {
  AXI4L_C2_WRITE_COMMIT,
  AXI4L_C2_READ_SNAPSHOT
} axi4l_c2_event_kind_e;

class axi4l_c2_event extends uvm_object;
  `uvm_object_utils(axi4l_c2_event)

  axi4l_c2_event_kind_e kind;
  axi4l_seq_item        request;
  longint unsigned     epoch;
  longint unsigned     event_cycle;
  bit                  whitebox_exact;

  function new(string name = "axi4l_c2_event");
    super.new(name);
  endfunction
endclass
