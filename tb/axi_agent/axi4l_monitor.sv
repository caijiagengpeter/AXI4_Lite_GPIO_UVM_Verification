class axi4l_monitor extends uvm_monitor;
  `uvm_component_utils(axi4l_monitor)

  typedef struct packed {
    bit [AXI4L_ADDR_WIDTH-1:0] addr;
    bit [2:0]                  prot;
    longint unsigned           cycle;
  } aw_sample_t;

  typedef struct packed {
    bit [AXI4L_DATA_WIDTH-1:0]   data;
    bit [AXI4L_DATA_WIDTH/8-1:0] strb;
    longint unsigned             cycle;
  } w_sample_t;

  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;
  // request_ap reports request acceptance; response_ap reports B/R
  // completion.  ap remains as a response-completion compatibility port.
  uvm_analysis_port #(axi4l_seq_item) request_ap;
  uvm_analysis_port #(axi4l_seq_item) response_ap;
  uvm_analysis_port #(axi4l_seq_item) ap;

  aw_sample_t      aw_queue[$];
  w_sample_t       w_queue[$];
  axi4l_seq_item   write_queue[$];
  axi4l_seq_item   read_queue[$];
  longint unsigned sample_cycle;
  longint unsigned next_write_id;
  longint unsigned next_read_id;

  function new(string name = "axi4l_monitor", uvm_component parent = null);
    super.new(name, parent);
    request_ap  = new("request_ap", this);
    response_ap = new("response_ap", this);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4l_if #(AXI4L_ADDR_WIDTH,
                                           AXI4L_DATA_WIDTH))::get(
          this, "", "vif", vif))
      `uvm_fatal("NOVIF", "axi4l_monitor did not receive its virtual interface")
  endfunction

  function void clear_queues();
    aw_queue.delete();
    w_queue.delete();
    write_queue.delete();
    read_queue.delete();
  endfunction

  function void publish_request(axi4l_seq_item tr);
    axi4l_seq_item copy;
    if (!$cast(copy, tr.clone()))
      `uvm_fatal("MON_CLONE", "Failed to clone accepted AXI request")
    request_ap.write(copy);
  endfunction

  function void publish_response(axi4l_seq_item tr);
    axi4l_seq_item copy;
    if (!$cast(copy, tr.clone()))
      `uvm_fatal("MON_CLONE", "Failed to clone completed AXI response")
    response_ap.write(copy);

    // Keep the original v1 response-only analysis API available to any
    // external component that still connects monitor.ap.
    if (!$cast(copy, tr.clone()))
      `uvm_fatal("MON_CLONE", "Failed to clone legacy AXI response")
    ap.write(copy);
  endfunction

  task run_phase(uvm_phase phase);
    aw_sample_t aw_sample;
    w_sample_t  w_sample;
    axi4l_seq_item tr;

    clear_queues();
    forever begin
      @(vif.mon_cb);
      sample_cycle++;

      if (vif.mon_cb.ARESETN !== 1'b1) begin
        clear_queues();
        continue;
      end

      if (vif.mon_cb.AWVALID && vif.mon_cb.AWREADY) begin
        aw_sample.addr = vif.mon_cb.AWADDR;
        aw_sample.prot = vif.mon_cb.AWPROT;
        aw_sample.cycle = sample_cycle;
        aw_queue.push_back(aw_sample);
      end

      if (vif.mon_cb.WVALID && vif.mon_cb.WREADY) begin
        w_sample.data = vif.mon_cb.WDATA;
        w_sample.strb = vif.mon_cb.WSTRB;
        w_sample.cycle = sample_cycle;
        w_queue.push_back(w_sample);
      end

      // Pair the oldest address with the oldest data.  AXI4-Lite has no IDs.
      while ((aw_queue.size() > 0) && (w_queue.size() > 0)) begin
        aw_sample = aw_queue.pop_front();
        w_sample  = w_queue.pop_front();
        tr = axi4l_seq_item::type_id::create("observed_write");
        tr.access = AXI4L_WRITE;
        tr.addr   = aw_sample.addr;
        tr.prot   = aw_sample.prot;
        tr.data   = w_sample.data;
        tr.strb   = w_sample.strb;
        tr.transaction_id = next_write_id++;
        tr.aw_cycle       = aw_sample.cycle;
        tr.w_cycle        = w_sample.cycle;
        tr.accept_cycle   = (aw_sample.cycle > w_sample.cycle)
                          ? aw_sample.cycle : w_sample.cycle;
        write_queue.push_back(tr);
        publish_request(tr);
      end

      if (vif.mon_cb.BVALID && vif.mon_cb.BREADY) begin
        if (write_queue.size() == 0) begin
          `uvm_error("MON_B", "Observed B handshake without a complete AW/W pair")
        end else begin
          tr = write_queue.pop_front();
          tr.resp = vif.mon_cb.BRESP;
          tr.response_cycle = sample_cycle;
          publish_response(tr);
        end
      end

      if (vif.mon_cb.ARVALID && vif.mon_cb.ARREADY) begin
        tr = axi4l_seq_item::type_id::create("observed_read");
        tr.access = AXI4L_READ;
        tr.addr   = vif.mon_cb.ARADDR;
        tr.prot   = vif.mon_cb.ARPROT;
        tr.transaction_id = next_read_id++;
        tr.accept_cycle   = sample_cycle;
        read_queue.push_back(tr);
        publish_request(tr);
      end

      if (vif.mon_cb.RVALID && vif.mon_cb.RREADY) begin
        if (read_queue.size() == 0) begin
          `uvm_error("MON_R", "Observed R handshake without an earlier AR handshake")
        end else begin
          tr = read_queue.pop_front();
          tr.rdata = vif.mon_cb.RDATA;
          tr.resp  = vif.mon_cb.RRESP;
          tr.response_cycle = sample_cycle;
          publish_response(tr);
        end
      end
    end
  endtask
endclass

