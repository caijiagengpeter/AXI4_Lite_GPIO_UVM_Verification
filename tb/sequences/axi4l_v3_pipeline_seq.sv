class axi4l_v3_pipeline_seq extends uvm_sequence #(axi4l_seq_item);
  `uvm_object_utils(axi4l_v3_pipeline_seq)

  localparam bit [1:0] AXI_OKAY = 2'b00;
  localparam int unsigned NUM_REQUESTS = 3;

  function new(string name = "axi4l_v3_pipeline_seq");
    super.new(name);
  endfunction

  task automatic send_write(
    int unsigned index,
    bit [AXI4L_ADDR_WIDTH-1:0] addr,
    bit [AXI4L_DATA_WIDTH-1:0] data,
    int unsigned aw_delay,
    int unsigned w_delay,
    int unsigned bready_delay
  );
    axi4l_seq_item req;
    req = axi4l_seq_item::type_id::create($sformatf("write_req_%0d", index));
    start_item(req);
    req.access         = AXI4L_WRITE;
    req.addr           = addr;
    req.data           = data;
    req.strb           = '1;
    req.prot           = 3'b000;
    req.aw_delay       = aw_delay;
    req.w_delay        = w_delay;
    req.bready_delay   = bready_delay;
    req.ar_delay       = 0;
    req.rready_delay   = 0;
    finish_item(req);
  endtask

  task automatic send_read(
    int unsigned index,
    bit [AXI4L_ADDR_WIDTH-1:0] addr,
    int unsigned rready_delay
  );
    axi4l_seq_item req;
    req = axi4l_seq_item::type_id::create($sformatf("read_req_%0d", index));
    start_item(req);
    req.access         = AXI4L_READ;
    req.addr           = addr;
    req.data           = '0;
    req.strb           = '1;
    req.prot           = 3'b000;
    req.aw_delay       = 0;
    req.w_delay        = 0;
    req.bready_delay   = 0;
    req.ar_delay       = 0;
    req.rready_delay   = rready_delay;
    finish_item(req);
  endtask

  task body();
    axi4l_seq_item rsp;
    axi4l_seq_item write_rsp[0:NUM_REQUESTS-1];
    axi4l_seq_item read_rsp[0:NUM_REQUESTS-1];
    bit [AXI4L_ADDR_WIDTH-1:0] write_addr[0:NUM_REQUESTS-1];
    bit [AXI4L_DATA_WIDTH-1:0] write_data[0:NUM_REQUESTS-1];
    bit [AXI4L_ADDR_WIDTH-1:0] read_addr[0:NUM_REQUESTS-1];
    bit [AXI4L_DATA_WIDTH-1:0] read_data[0:NUM_REQUESTS-1];

    // The sequence deliberately issues all requests before calling
    // get_response().  Unlimited local response storage avoids the standard
    // UVM depth-eight response queue becoming an accidental traffic limit.
    set_response_queue_depth(-1);

    write_addr[0] = 5'h00; // LOAD: gives the later read a non-zero value.
    write_addr[1] = 5'h18; // MASK: independent register and non-zero value.
    write_addr[2] = 5'h10; // INPUT is read-only; still returns an OKAY BRESP.
    write_data[0] = 32'h1357_9bdf;
    write_data[1] = 32'h0000_0015;
    write_data[2] = 32'hcafe_0003;

    // A is AW-first, B is W-first, and C presents AW/W together.  Holding
    // A's BREADY low creates deterministic accepted-request overlap.
    send_write(0, write_addr[0], write_data[0], 0, 3, 16);
    send_write(1, write_addr[1], write_data[1], 3, 0, 0);
    send_write(2, write_addr[2], write_data[2], 0, 0, 0);

    for (int i = 0; i < NUM_REQUESTS; i++) begin
      get_response(rsp);
      if (!$cast(write_rsp[i], rsp.clone()))
        `uvm_fatal("V3_RSP_CLONE", "Failed to retain write response")
      `uvm_info("V3_SEQ_WRITE_RSP",
        $sformatf("request[%0d] issue_cycle=%0d response_cycle=%0d addr=0x%0h data=0x%08h BRESP=%02b seq_id=%0d tr_id=%0d",
                  i, rsp.accept_cycle, rsp.response_cycle,
                  rsp.addr, rsp.data, rsp.resp, rsp.get_sequence_id(),
                  rsp.get_transaction_id()), UVM_NONE)
      if (rsp.transaction_aborted)
        `uvm_error("V3_WRITE_ABORT", $sformatf("write %0d was aborted", i))
      if ((rsp.addr != write_addr[i]) || (rsp.data != write_data[i]))
        `uvm_error("V3_WRITE_ORDER",
          $sformatf("write response %0d does not match request order", i))
      if (rsp.resp !== AXI_OKAY)
        `uvm_error("V3_WRITE_RESP",
          $sformatf("write %0d returned BRESP=%02b", i, rsp.resp))
    end

    if (!(write_rsp[1].accept_cycle < write_rsp[0].response_cycle))
      `uvm_error("V3_WRITE_NO_OVERLAP",
        $sformatf("write B issue cycle %0d was not before write A response cycle %0d",
                  write_rsp[1].accept_cycle, write_rsp[0].response_cycle))

    read_addr[0] = 5'h00;
    read_addr[1] = 5'h18;
    read_addr[2] = 5'h10;
    read_data[0] = write_data[0];
    read_data[1] = write_data[1];
    read_data[2] = '0;

    send_read(0, read_addr[0], 16);
    send_read(1, read_addr[1], 0);
    send_read(2, read_addr[2], 0);

    for (int i = 0; i < NUM_REQUESTS; i++) begin
      get_response(rsp);
      if (!$cast(read_rsp[i], rsp.clone()))
        `uvm_fatal("V3_RSP_CLONE", "Failed to retain read response")
      `uvm_info("V3_SEQ_READ_RSP",
        $sformatf("request[%0d] issue_cycle=%0d response_cycle=%0d addr=0x%0h RDATA=0x%08h RRESP=%02b seq_id=%0d tr_id=%0d",
                  i, rsp.accept_cycle, rsp.response_cycle,
                  rsp.addr, rsp.rdata, rsp.resp, rsp.get_sequence_id(),
                  rsp.get_transaction_id()), UVM_NONE)
      if (rsp.transaction_aborted)
        `uvm_error("V3_READ_ABORT", $sformatf("read %0d was aborted", i))
      if (rsp.addr != read_addr[i])
        `uvm_error("V3_READ_ORDER",
          $sformatf("read response %0d addr=0x%0h, expected 0x%0h",
                    i, rsp.addr, read_addr[i]))
      if (rsp.resp !== AXI_OKAY)
        `uvm_error("V3_READ_RESP",
          $sformatf("read %0d returned RRESP=%02b", i, rsp.resp))
      if (rsp.rdata !== read_data[i])
        `uvm_error("V3_READ_DATA",
          $sformatf("read %0d addr=0x%0h returned 0x%08h, expected 0x%08h",
                    i, rsp.addr, rsp.rdata, read_data[i]))
    end

    if (!(read_rsp[1].accept_cycle < read_rsp[0].response_cycle))
      `uvm_error("V3_READ_NO_OVERLAP",
        $sformatf("read B issue cycle %0d was not before read A response cycle %0d",
                  read_rsp[1].accept_cycle, read_rsp[0].response_cycle))

    `uvm_info("V3_PIPELINE_PROOF",
      $sformatf("WRITE A(issue=%0d rsp=%0d) B(issue=%0d rsp=%0d) C(issue=%0d rsp=%0d); READ A(issue=%0d rsp=%0d) B(issue=%0d rsp=%0d) C(issue=%0d rsp=%0d)",
                write_rsp[0].accept_cycle, write_rsp[0].response_cycle,
                write_rsp[1].accept_cycle, write_rsp[1].response_cycle,
                write_rsp[2].accept_cycle, write_rsp[2].response_cycle,
                read_rsp[0].accept_cycle, read_rsp[0].response_cycle,
                read_rsp[1].accept_cycle, read_rsp[1].response_cycle,
                read_rsp[2].accept_cycle, read_rsp[2].response_cycle), UVM_NONE)
  endtask
endclass
