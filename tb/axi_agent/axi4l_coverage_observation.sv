typedef enum int unsigned {
  AXI4L_RESET_IDLE,
  AXI4L_RESET_AW_ONLY,
  AXI4L_RESET_W_ONLY,
  AXI4L_RESET_WRITE_PENDING,
  AXI4L_RESET_READ_PENDING,
  AXI4L_RESET_B_STALLED,
  AXI4L_RESET_R_STALLED
} axi4l_reset_context_e;

// Passive, cycle-level facts published by the AXI monitor.  These are
// observations of interface handshakes/stalls and monitor FIFO occupancy;
// no sequence intent or expected value is carried here.
class axi4l_bus_observation extends uvm_object;
  `uvm_object_utils(axi4l_bus_observation)

  longint unsigned sample_cycle;
  bit reset_n;
  bit reset_enter;
  bit reset_exit;
  bit aw_handshake;
  bit w_handshake;
  bit ar_handshake;
  bit b_handshake;
  bit r_handshake;
  bit aw_stall;
  bit w_stall;
  bit b_stall;
  bit r_stall;
  int unsigned write_outstanding;
  int unsigned read_outstanding;
  int unsigned write_highwater;
  int unsigned read_highwater;
  axi4l_reset_context_e reset_context;

  function new(string name = "axi4l_bus_observation");
    super.new(name);
  endfunction
endclass

// Coverage-facing copy of a real C2 execution event.  The scoreboard keeps
// its existing axi4l_c2_event API; this common agent-level type avoids a
// package dependency from coverage back into the environment.
class axi4l_timing_observation extends uvm_object;
  `uvm_object_utils(axi4l_timing_observation)

  bit is_write_commit;
  axi4l_seq_item request;
  longint unsigned epoch;
  longint unsigned event_cycle;
  bit whitebox_exact;

  function new(string name = "axi4l_timing_observation");
    super.new(name);
  endfunction
endclass
