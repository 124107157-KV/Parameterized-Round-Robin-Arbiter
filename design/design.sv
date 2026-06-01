`timescale 1ns/1ps

// ============================================================================
// Round Robin Arbiter
// ----------------------------------------------------------------------------
// Features:
//   - Parameterized number of requesters
//   - One-hot grant output
//   - Fixed-priority search starting from a rotating pointer
//   - Pointer advances after every successful grant
//   - No grant when no request is active
//
// Protocol:
//   req[i]   = requester i is requesting service
//   grant[i] = requester i receives grant
//
// This is a simple single-cycle combinational grant arbiter with a registered
// round-robin pointer.
// ============================================================================

module rr_arbiter #(
    parameter int N = 4
)(
    input  logic         clk,
    input  logic         rst_n,

    input  logic [N-1:0] req,
    output logic [N-1:0] grant,
    output logic         grant_valid
);

    localparam int IDX_W = (N <= 1) ? 1 : $clog2(N);

    logic [IDX_W-1:0] pointer_q;

    logic [N-1:0] grant_comb;
    logic         grant_valid_comb;

    // ------------------------------------------------------------------------
    // Grant generation
    // ------------------------------------------------------------------------
    // The arbiter checks requesters starting from pointer_q.
    //
    // Example for N = 4:
    //   pointer_q = 0 -> priority order: 0, 1, 2, 3
    //   pointer_q = 1 -> priority order: 1, 2, 3, 0
    //   pointer_q = 2 -> priority order: 2, 3, 0, 1
    //   pointer_q = 3 -> priority order: 3, 0, 1, 2
    // ------------------------------------------------------------------------

    always_comb begin
        grant_comb       = '0;
        grant_valid_comb = 1'b0;

        for (int offset = 0; offset < N; offset++) begin
            int unsigned idx;
            idx = (pointer_q + offset) % N;

            if (!grant_valid_comb && req[idx]) begin
                grant_comb[idx]       = 1'b1;
                grant_valid_comb      = 1'b1;
            end
        end
    end

    assign grant       = grant_comb;
    assign grant_valid = grant_valid_comb;

    // ------------------------------------------------------------------------
    // Round-robin pointer update
    // ------------------------------------------------------------------------
    // After requester i is granted, the next search starts from i + 1.
    // If requester N-1 is granted, the pointer wraps to 0.
    // ------------------------------------------------------------------------

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pointer_q <= '0;
        end
        else if (grant_valid_comb) begin
            for (int i = 0; i < N; i++) begin
                if (grant_comb[i]) begin
                    if (i == N-1)
                        pointer_q <= '0;
                    else
                        pointer_q <= i + 1;
                end
            end
        end
    end

endmodule
