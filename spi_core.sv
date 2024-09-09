/*
This module is designed to act as an SPI master in mode 0 for a configurable number of slaves.  Clock generation is NOT done in this module, it must be fed the SPI clock
either from a PLL/divider module or the system clock.

NOTES FOR USE:
- Data must be available for at least 1.5 SPI clock periods on tx_data line to be loaded into the shift register
- Received data is available until the next transfer completes
*/

module SPI_MASTER 
#(
    parameter   WORD_SIZE = 16,
                SLAVE_COUNT = 2     
                //Passed slave count must be >= 2 ($clog2 function returns 0 for an argument of 1.  I don't make the rules, blame mathematics).  
                //If only using one slave, leave the second CS output unconnected.
)

(
    input   logic                           clk,            // SPI clock input from Master
    input   logic                           reset_n,        // Active low reset input
    input   logic                           start,          // Start transmission
    input   logic [$clog2(SLAVE_COUNT)-1:0] chip_select,    // Chip select
    input   logic                           spi_miso,       // Master in slave out

    output  logic                           spi_clk,        // Serial clock output
    output  logic                           spi_mosi,       // Master out slave in
    output  logic                           ready,          // Ready signal

    output  logic [SLAVE_COUNT-1:0]         spi_cs,         // Chip select outputs
    input   logic [WORD_SIZE-1:0]           tx_data,        // Data to transmit
    output  logic [WORD_SIZE-1:0]           rx_data         // Received data
);

    logic [WORD_SIZE-1:0] data_reg;             // Shift register
    logic shift_en;                             // Shift enable signal for the data register
    logic [$clog2(WORD_SIZE)-1:0] bit_count;    // Bit count for data transmission
    logic load_reg;                             // Signal to load data from tx_data to data_reg
    logic miso_reg;                             // Sampled data from the MISO line to be shifted into data_reg
    logic spi_clk_enable;                       
    logic mosi_enable;
    logic transfer_in_progress;                 // Holds the state machine in the transfer state until all bits have been shifted out

    enum bit [1 : 0] {IDLE, LOAD_DATA, TRANSFER, RECEIVE} state;

    //assign selected_cs = chip_select;
    assign spi_mosi = data_reg[WORD_SIZE-1] && mosi_enable;
    assign spi_clk = clk && spi_clk_enable;

    //miso sample
    always_ff @(posedge clk or negedge reset_n) begin
        if(~reset_n) miso_reg <= 0;
        else miso_reg <= spi_miso;
    end

    //shift register
    always_ff @(negedge clk or negedge reset_n) begin
        if(~reset_n) begin
            {data_reg, bit_count, transfer_in_progress} <= 0;
        end
        else if(load_reg) begin 
            data_reg <= tx_data;
            transfer_in_progress <= 1'b1;
        end
        else if(shift_en) begin
            if(bit_count < (WORD_SIZE-1)) begin
                data_reg <= {data_reg[WORD_SIZE-2:0], miso_reg};
                bit_count <= bit_count + 1'b1;
            end
            else begin
                data_reg <= {data_reg[WORD_SIZE-2:0], miso_reg};
                {bit_count, transfer_in_progress} <= 0;
            end
        end
    end

    //state machine
    always_ff @(posedge clk or negedge reset_n) begin
        if(~reset_n) begin
            {state, load_reg, ready, shift_en, mosi_enable, spi_clk_enable, rx_data} = 0;
            spi_cs <= '1;
        end
        else begin
            case(state)
                IDLE:       begin
                                if(start) begin
                                    state <= LOAD_DATA;
                                    load_reg <= 1'b1;
                                    ready <= 0;
                                end
                                else begin
                                    state <= IDLE;
                                    ready <= 1'b1;
                                end
                            end

                LOAD_DATA:  begin
                                state <= TRANSFER;
                                load_reg <= 0;
                                mosi_enable <= 1'b1;
                                spi_cs[chip_select] <= 0;
                            end

                TRANSFER:   begin
                                if(transfer_in_progress) begin
                                    state <= TRANSFER;
                                    spi_clk_enable <= 1'b1;
                                    shift_en <= 1'b1;
                                end
                                else begin
                                    state <= RECEIVE;
                                    spi_clk_enable <= 0;
                                    mosi_enable <= 0;
                                    shift_en <= 0;
                                    spi_cs[chip_select] <= 1;
                                end
                            end

                RECEIVE:    begin
                                state <= IDLE;
                                rx_data <= data_reg;
                                ready <= 1'b1;
                            end
            endcase
        end
    end

endmodule