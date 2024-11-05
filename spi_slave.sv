/*-----------------------------------------------------------------------------------------------------
This is a general SPI slave module that can be used to interface with a master device. The module
receives data from the master device and stores it in a register. The module has a state machine that
waits for the chip select signal to go low, then waits for the master to send data on the input clock.
-------------------------------------------------------------------------------------------------------*/

module SPI_SLAVE #(
    parameter WORD_SIZE = 32, //changed from 16 to 32
	 parameter ADDR_SIZE = 8,
    parameter SPI_MODE = 0,
	 parameter DATA_SIZE = 24,
	 parameter REG_SIZE = 8  //a byte length for the spi register 
	 
	 )
	 (
		// Control signals
		input logic clk,
		input logic reset_n,
		output logic lastAddrflag, //flash to signal the 0x3f has reached
		
		//addresses - 8 bit 
		output logic [ADDR_SIZE - 1:0] ram_addr,  //addr send to RAM block to cue for data
		input logic [WORD_SIZE - 1:0] ram_data, //data read from ram - temp data for testing
		
		//output logic [WORD_SIZE-1:0] rx_data, not sure why rx is an output 
		//output logic [WORD_SIZE - 1:0] tx_data,  //[spare, RW, data], b31-b24, b23=rw, b22-b0 = data
		
		// SPI communication
		input logic input_spi_clk, //the clock coming from master
		input logic spi_mosi, // master out slave in bits
		input logic spi_cs, // Active low chip select
		output logic spi_miso // master in slave out bits
		//output logic dummy
	);
	
	enum bit [2 : 0] {IDLE, PREP_DATA, RECEIVE_DATA} state; //state machine states - change to [2:0] to add more states

   logic [REG_SIZE - 1:0] shift_reg = 0; //Register to temporarily hold received data
	logic [REG_SIZE - 1:0] byte_inbuff = 0;  //buffer for incoming traffic since incoming and outgoing data are on different edges and need diff alwaysff
	logic [DATA_SIZE - 1:0] byte_outbuff = 0;
	//logic [$clog2(WORD_SIZE) - 1:0] bit_counter_out;  // Counter for sent bits, bit_counter = 4, $clog2(16)= 4, $clog2(32)= 5,
	logic [$clog2(REG_SIZE) - 1:0] bit_counter = 0;  // Counter for received/sent bits, bit_counter, 8bit counter for both tx & rx
	logic [2:0] tx_bit_counter; //transfer bit counter
   logic tx_done = 0;
   logic rx_done = 0; 	//flag to signal when data has been received
   logic [WORD_SIZE - 1:0] i = 0; 
	logic [DATA_SIZE - 1:0] j = 0;
	logic [1:0] cyc_cnt = 0;
	logic cyc_cnt_done = 0; //flag to signal when 2 rising edges cycle is done and read to capture ram data
	//logic [ADDR_SIZE - 1:0] addr_reg = 0;
	logic [$clog2(WORD_SIZE) - 1:0] byte_counter = 0;
	logic addr_set = 0;
	//logic set_addr = 0;
	logic read_ram = 0;
	logic send_data = 0;
	logic mosi_en = 0;
	
	

    //run on input clock signal to receive data when CS is held low
    always_ff @(posedge input_spi_clk or negedge reset_n) begin  //changed from posedge input_spi_clk to neg		
        if (~reset_n) begin
            shift_reg <= 0;
				///addr_reg <= 0;
            bit_counter <= 0;			
				byte_counter <= 0;
            rx_done <= 0;
				tx_done <= 0;
				spi_miso <= 0;
				tx_bit_counter <=0;

        end 
		  else if (~spi_cs) begin
				
				//make mosi for address 8 bit 
				if (mosi_en == 1) begin
					byte_inbuff <= {byte_inbuff[REG_SIZE-1:0], spi_mosi};  
					//addr_reg <= {addr_reg[ADDR_SIZE - 1:0], spi_mosi};  //b7-b0 *might need to do ADDR_SIZE-2:0.	
					//increment counter
					bit_counter <= bit_counter + 1;
				end
				else if (send_data == 1) begin
					if (byte_counter == 0 ) begin
						for (j = 0; j <= 7; j = j + 1) begin  //*****data is latching,  need to find a way to unlatch it*************************
							shift_reg[j] <= byte_outbuff[j];  	
						end		
					end
					else if (byte_counter == 1 ) begin
						for (j = 8; j <= 15; j = j + 1) begin
							shift_reg[j-8] <= byte_outbuff[j];  
						end		
					end
					else if (byte_counter == 2 ) begin
						for (j = 16; j <= 23; j = j + 1) begin
							shift_reg[j-16] <= byte_outbuff[j];  // here could make a j-lshift, lshift changes based on counter
						end		
					end
					
					spi_miso <= {shift_reg[REG_SIZE-1:0], shift_reg};
					tx_bit_counter <= tx_bit_counter + 1;	
				end
				
				if (tx_bit_counter == REG_SIZE - 1) begin
					byte_counter <= byte_counter + 1; //byte count up to keep track the chunk of byte
					tx_bit_counter <= 0;
				
					if (byte_counter >= 3) begin
						tx_done <= 0;
						byte_counter <= 0;
						if (ram_addr == 2'h3f) begin
							lastAddrflag <= 0;
						end
					end
				end
            if (bit_counter == REG_SIZE - 1) begin
					rx_done <= 1;
            end 
				else begin
                rx_done <= 0;
            end			
        end 
		  else begin
            bit_counter <= 0;
            rx_done <= 0;
        end
    end
	 
	 //process to set add and perhaps data on -ve clk
	always_ff @(negedge clk) begin
		if (~reset_n ) begin
			ram_addr <= 0;
			//{read_ram} <= 0;
			//ram_data <= 0;
		end
		else if (~spi_cs) begin //send address
			//set address 
			if (byte_inbuff[7] == 1) begin
				for (i = 0; i <= 5; i = i + 1) begin //only sending 6 bit to ram during negedge clk cycle
					ram_addr[i] <= byte_inbuff[i];
				end
			end 
			if (rx_done) begin
				addr_set <= 1; //flag address set for state transition -wait for two clock cycles before grabbing the ram data, if cyc_cnt_done is true, ram data is now in shift_reg
			end
			else begin
				addr_set <= 0;
			end
		end
	end
	
	// +ve clk for cycle count x2
	always_ff @(posedge clk) begin
		if (~reset_n) begin
			cyc_cnt <= 0;
			cyc_cnt_done <= 0;
		end
		else if (addr_set) begin
			cyc_cnt <= cyc_cnt + 1;
		end

		if (cyc_cnt == 1) begin
			cyc_cnt_done <= 1;
			byte_outbuff <= ram_data;
			//spi_miso <= byte_outbuff[j]; 
			cyc_cnt <= 0;
		end
		else begin
			cyc_cnt_done <= 0;
		end
	end

    //state machine to get bits in SPI
    always_ff @(posedge clk or negedge reset_n) begin
		if (~reset_n) begin
            state <= IDLE;
				mosi_en <= 0;
				send_data <= 0;
            //ram_addr <= 0;
				//ram_data <= 0;
		end 
		else begin
            case(state)
                //wait for cs to go low, then receive data
                IDLE:begin
								if(~spi_cs) begin								
									state <= PREP_DATA;
								end
								else begin
									state <= IDLE;
								end
							end
							
					 PREP_DATA:begin
								mosi_en <= 1;
								// send addr to ram and cue for specific data in bus
								if (cyc_cnt_done) begin
									
									state <= RECEIVE_DATA;
								end
								else if (spi_cs) begin
									state <= IDLE;
								end
							end
                
                //wait for data to be received on input clock, then store data on internal clock
                RECEIVE_DATA:begin
								if (~reset_n || ~spi_cs) begin
									mosi_en <= 0;
									send_data <= 1;
								end
								else if (tx_done) begin //this might not needed, mcu might send chip select high to go back to IDLE
									state <= IDLE;
								end
									// spi_miso <= {shift_reg[REG_SIZE-1:0], shift_reg};
								else if (spi_cs) begin // if a posedge from chip select, it goes back to idle
									state <= IDLE;
								end 
							end
					
            endcase
		end
	end
	 
endmodule