class axi4l_single_access_seq extends uvm_sequence #(axi4l_seq_item);
  `uvm_object_utils(axi4l_single_access_seq)

  axi4l_access_e                    access;
  bit [AXI4L_ADDR_WIDTH-1:0]        addr;
  bit [AXI4L_DATA_WIDTH-1:0]        data;
  bit [AXI4L_DATA_WIDTH/8-1:0]      strb = '1;
  int unsigned                      aw_delay;
  int unsigned                      w_delay;
  int unsigned                      ar_delay;
  int unsigned                      response_delay = 1;

  function new(string name = "axi4l_single_access_seq");
    super.new(name);
  endfunction

  task body();
    axi4l_seq_item tr;
    tr = axi4l_seq_item::type_id::create("tr");
    start_item(tr);
    tr.access       = access;
    tr.addr         = addr;
    tr.data         = data;
    tr.strb         = strb;
    tr.prot         = 3'b000;
    tr.aw_delay     = aw_delay;
    tr.w_delay      = w_delay;
    tr.ar_delay     = ar_delay;
    tr.bready_delay = response_delay;
    tr.rready_delay = response_delay;
    finish_item(tr);
  endtask
endclass
