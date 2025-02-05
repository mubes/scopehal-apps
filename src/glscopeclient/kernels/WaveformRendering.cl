/***********************************************************************************************************************
*                                                                                                                      *
* GLSCOPECLIENT v0.1                                                                                                   *
*                                                                                                                      *
* Copyright (c) 2012-2021 Andrew D. Zonenberg and contributors                                                         *
* All rights reserved.                                                                                                 *
*                                                                                                                      *
* Redistribution and use in source and binary forms, with or without modification, are permitted provided that the     *
* following conditions are met:                                                                                        *
*                                                                                                                      *
*    * Redistributions of source code must retain the above copyright notice, this list of conditions, and the         *
*      following disclaimer.                                                                                           *
*                                                                                                                      *
*    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the       *
*      following disclaimer in the documentation and/or other materials provided with the distribution.                *
*                                                                                                                      *
*    * Neither the name of the author nor the names of any contributors may be used to endorse or promote products     *
*      derived from this software without specific prior written permission.                                           *
*                                                                                                                      *
* THIS SOFTWARE IS PROVIDED BY THE AUTHORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED   *
* TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL *
* THE AUTHORS BE HELD LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES        *
* (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR       *
* BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT *
* (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE       *
* POSSIBILITY OF SUCH DAMAGE.                                                                                          *
*                                                                                                                      *
***********************************************************************************************************************/

//Maximum height of a single waveform, in pixels.
//This is enough for a nearly fullscreen 4K window so should be plenty.
#define MAX_HEIGHT		2048

//Number of threads per column of pixels
#define THREADS_PER_BLOCK	64

/**
	@brief Linearly interpolate Y coordinates
 */
float InterpolateY(float leftx, float lefty, float slope, float x)
{
	return lefty + ( (x-leftx)*slope );
}

/**
	@brief Render a dense-packed analog waveform

	@param plotRight		Right edge of displayed waveform
	@param width			Width of the image
	@param height			Height of the image
	@param firstcol			Index of the column corresponding to global ID of 0
							(may be nonzero if the image is more than CL_DEVICE_MAX_WORK_GROUP_SIZE pixels wide)
	@param depth			Number of samples in the waveform
	@param innerXoff		X offset (in samples)
	@param offsetSamples	X offset (in samples)
	@param alpha			Alpha value for intensity grading
	@param xoff				X offset (in X units)
	@param xscale			X scale (pixels/X unit)
	@param ybase			Y position of zero (for overlays etc)
	@param yscale			Y scale
	@param yoff				Y offset
	@param persistScale		Decay factor for persistence
	@param ypos				Y coordinates of output waveform
	@param outbuf			Output waveform buffer
 */
__kernel void RenderDensePackedAnalogWaveform(
	unsigned int plotRight,
	unsigned int width,
	unsigned int height,
	unsigned long firstcol,
	unsigned long depth,
	unsigned long innerXoff,
	unsigned long offsetSamples,
	float alpha,
	unsigned long xoff,
	float xscale,
	float ybase,
	float yscale,
	float yoff,
	float persistScale,	//unimplemented for now
	__global float* ypos,
	__global float* outbuf
	)
{
	//Shared buffer for the current column of pixels (8 kB)
	__local float workingBuffer[MAX_HEIGHT];

	//Min/max for the current sample
	__local int blockmin[THREADS_PER_BLOCK];
	__local int blockmax[THREADS_PER_BLOCK];
	__local bool updating[THREADS_PER_BLOCK];

	//Abort if invalid parameters
	if(height > MAX_HEIGHT)
		return;
	if(depth < 2)
		return;

	//Figure out coordinate range of interest. Don't do anything if we're off the right end of the buffer
	unsigned long x = get_global_id(0) + firstcol;
	unsigned long tid = get_local_id(1);
	unsigned long istart = floor(x / xscale) + offsetSamples;
	unsigned long iend = floor((x + 1)/xscale) + offsetSamples;
	if(x >= width)
		return;

	//Clear working buffer
	//TODO: persistence
	for(unsigned int y=tid; y<height; y += THREADS_PER_BLOCK)
		workingBuffer[y] = 0;

	//Not done unless we're already off the plot
	bool skipmainloop;
	if(iend <= 0)
		skipmainloop = true;
	else if(x >= plotRight)
		skipmainloop = true;
	else
		skipmainloop = false;

	//Main loop
	if(!skipmainloop)
	{
		unsigned long ibase = istart;
		while(ibase < (depth-1))
		{
			//First sample of the thread group off the plot? Done
			float base_leftx = (ibase + innerXoff) * xscale + xoff;
			if(base_leftx > (x+1) )
				break;

			unsigned long i = ibase + tid;
			if(i < (depth - 1))
			{
				//Get raw coordinates
				float leftx = (i + innerXoff) * xscale + xoff;
				float lefty = (ypos[i] + yoff) * yscale + ybase;
				float rightx = (i + 1 + innerXoff) * xscale + xoff;
				float righty = (ypos[i+1] + yoff) * yscale + ybase;

				//Skip offscreen
				if( (rightx >= x) && (leftx <= x+1) )
				{
					float starty = lefty;
					float endy = righty;

					//Interpolate
					float slope = (righty - lefty) / (rightx - leftx);
					if(leftx < x)
						starty = InterpolateY(leftx, lefty, slope, x);
					else
						endy = InterpolateY(leftx, lefty, slope, x+1);

					//Clip to window size
					starty = min(starty, (float)(MAX_HEIGHT-1));
					endy = min(endy, (float)(MAX_HEIGHT-1));
					starty = max(starty, 0.0f);
					endy = max(endy, 0.0f);

					//Sort coordinates
					blockmin[tid] = min(starty, endy);
					blockmax[tid] = max(starty, endy);

					//At end of pixel? Stop
					if(rightx > x+1)
					{}

					updating[tid] = true;
				}

				//nothing to do
				else
					updating[tid] = false;
			}
			else
				updating[tid] = false;

			ibase += THREADS_PER_BLOCK;

			//Update the shared buffer
			for(int thread = 0; thread < THREADS_PER_BLOCK; thread++)
			{
				barrier(CLK_LOCAL_MEM_FENCE);

				if(updating[thread])
				{
					int ymin = blockmin[thread];
					int ymax = blockmax[thread];
					for(int y = ymin + tid; y <= ymax; y+= THREADS_PER_BLOCK)
						workingBuffer[y] += alpha;
				}
			}
		}
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	//Copy working buffer to output
	for(unsigned long y=tid; y<height; y += THREADS_PER_BLOCK)
		outbuf[y*width + x] = workingBuffer[y];
}
