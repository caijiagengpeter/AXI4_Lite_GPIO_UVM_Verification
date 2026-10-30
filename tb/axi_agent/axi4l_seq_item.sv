typedef enum bit {
  AXI4L_READ,
  AXI4L_WRITE
} axi4l_access_e;

class axi4l_seq_item extends uvm_sequence_item;
  rand axi4l_access_e                    access;
  rand bit [AXI4L_ADDR_WIDTH-1:0]        addr;
  rand bit [AXI4L_DATA_WIDTH-1:0]        data;
  rand bit [AXI4L_DATA_WIDTH/8-1:0]      strb;
  rand bit [2:0]                         prot;
  rand int unsigned                      aw_delay;
  rand int unsigned                      w_delay;
  rand int unsigned                      ar_delay;
  rand int unsigned                      bready_delay;
  rand int unsigned                      rready_delay;

  // Filled by the driver or monitor.  These are observations, not stimulus.
  // Four-state response fields preserve 'x on synthetic reset-abort
  // responses.  transaction_aborted is the validity discriminator; BRESP,
  // RRESP, and RDATA are intentionally invalid when it is set.
  logic [1:0]                            resp;
  logic [AXI4L_DATA_WIDTH-1:0]           rdata;
  // Set on a synthetic response when reset aborts a request that the driver
  // has already consumed.  A normal B/R handshake always leaves this clear.
  bit                                    transaction_aborted;

  // V2 monitor metadata.  A logical request is published when AW/W have
  // both handshaken (or when AR handshakes), independently of the later
  // B/R response-completion event.
  longint unsigned                       transaction_id;
  longint unsigned                       accept_cycle;
  longint unsigned                       response_cycle;
  longint unsigned                       aw_cycle;
  longint unsigned                       w_cycle;

  constraint reasonable_delay_c {
    aw_delay     inside {[0:20]};
    w_delay      inside {[0:20]};
    ar_delay     inside {[0:20]};
    bready_delay inside {[0:20]};
    rready_delay inside {[0:20]};
  }

  `uvm_object_utils_begin(axi4l_seq_item)
    `uvm_field_enum(axi4l_access_e, access, UVM_DEFAULT)
    `uvm_field_int(addr,         UVM_HEX)
    `uvm_field_int(data,         UVM_HEX)
    `uvm_field_int(strb,         UVM_HEX)
    `uvm_field_int(prot,         UVM_HEX)
    `uvm_field_int(aw_delay,     UVM_DEC)
    `uvm_field_int(w_delay,      UVM_DEC)
    `uvm_field_int(ar_delay,     UVM_DEC)
    `uvm_field_int(bready_delay, UVM_DEC)
    `uvm_field_int(rready_delay, UVM_DEC)
    `uvm_field_int(resp,         UVM_HEX | UVM_NOCOMPARE)
    `uvm_field_int(rdata,        UVM_HEX | UVM_NOCOMPARE)
    `uvm_field_int(transaction_aborted, UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(transaction_id, UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(accept_cycle,   UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(response_cycle, UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(aw_cycle,       UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(w_cycle,        UVM_DEC | UVM_NOCOMPARE)
  `uvm_object_utils_end

  function new(string name = "axi4l_seq_item");
    super.new(name);
    strb = '1;
    prot = '0;
  endfunction
endclass

