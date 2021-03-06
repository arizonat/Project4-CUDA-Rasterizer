/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya
 * @date      2012-2015
 * @copyright University of Pennsylvania & STUDENT
 */

#include "rasterize.h"

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <thrust/random.h>
#include <util/checkCUDAError.h>
#include "rasterizeTools.h"
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/constants.hpp>
#include <glm/gtc/matrix_inverse.hpp>
#include <glm/gtc/constants.hpp>

#define MAX_THREADS 128

#define AA 1

//TODO: Make this into a parameter of some kind, allow setting of scale/rot/trans
#define NUM_INSTANCES 1

static int iter;

static int width = 0;
static int height = 0;
static int *dev_bufIdx = NULL;
static int *dev_bufIdxOut = NULL;
static VertexIn *dev_bufVertex = NULL;
static VertexOut *dev_bufVertexOut = NULL;
static Triangle *dev_primitives = NULL;
static Fragment *dev_depthbuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;
static int bufIdxSize = 0;
static int vertCount = 0;
static int vertInCount = 0;
static int vertOutCount = 0;
static Light light;

static int fragCount;
static int primCount;
static int numVertBlocks;
static int numVertInBlocks;
static int numVertOutBlocks;
static int numPrimBlocks;
static int numFragBlocks;

static glm::mat4 Mpvms[NUM_INSTANCES];
static glm::mat3 Mms[NUM_INSTANCES];

static glm::mat4* dev_Mpvms;
static glm::mat3* dev_Mms;

//static Cam cam; 
static glm::mat4 Mview;
static glm::mat4 Mmod;
static glm::mat4 Mproj;

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

// Writes fragment colors to the framebuffer
__global__
void render(int w, int h, Fragment *depthbuffer, glm::vec3 *framebuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {

		int tlx = x*AA;
		int tly = y*AA;

		glm::vec3 color(0.0);

		int sx, sy;
		for (int i = 0; i < AA; i++){
			for (int j = 0; j < AA; j++){
				sx = tlx + i;
				sy = tly + j;
				color += depthbuffer[sx+sy*w*AA].color;
			}
		}

		color /= AA*AA;

        framebuffer[index] = color;
    }
}

__global__ void initDepths(int n, Fragment* depthbuffer){
	int index = threadIdx.x + (blockDim.x*blockIdx.x);

	if (index < n){
		depthbuffer[index].fixed_depth = INT_MAX;
	}
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;

    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec3));
    cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));

	light.pos = glm::vec3(3.0, 3.0, 3.0);
	iter = 0;
    checkCUDAError("rasterizeInit");
}

/**
 * Set all of the buffers necessary for rasterization.
 */
void rasterizeSetBuffers(
        int _bufIdxSize, int *bufIdx,
        int _vertCount, float *bufPos, float *bufNor, float *bufCol) {
    bufIdxSize = _bufIdxSize;
    vertCount = _vertCount;

	// Vertex shading
	vertInCount = _vertCount;
	vertOutCount = vertInCount * NUM_INSTANCES;
	fragCount = width * height * AA * AA;
	primCount = vertOutCount / 3;
	numVertBlocks = (vertCount - 1) / MAX_THREADS + 1;
	numVertInBlocks = (vertInCount - 1) / MAX_THREADS + 1;
	numVertOutBlocks = (vertOutCount - 1) / MAX_THREADS + 1;
	numPrimBlocks = (primCount - 1) / MAX_THREADS + 1;
	numFragBlocks = (fragCount - 1) / MAX_THREADS + 1;

	printf("fragment count: %d\n", fragCount);
	printf("vertex count: %d\n", vertCount);
	printf("primitive count: %d\n", primCount);

	//int numBlocks = (width*height - 1) / MAX_THREADS + 1;
	//initDepths<<<numBlocks, MAX_THREADS>>>(width*height, dev_depthbuffer);

    cudaFree(dev_bufIdx);
    cudaMalloc(&dev_bufIdx, bufIdxSize * sizeof(int));
    cudaMemcpy(dev_bufIdx, bufIdx, bufIdxSize * sizeof(int), cudaMemcpyHostToDevice);

    VertexIn *bufVertex = new VertexIn[_vertCount];
    for (int i = 0; i < vertCount; i++) {
        int j = i * 3;
        bufVertex[i].pos = glm::vec3(bufPos[j + 0], bufPos[j + 1], bufPos[j + 2]);
        bufVertex[i].nor = glm::vec3(bufNor[j + 0], bufNor[j + 1], bufNor[j + 2]);
        bufVertex[i].col = glm::vec3(bufCol[j + 0], bufCol[j + 1], bufCol[j + 2]);
    }
    cudaFree(dev_bufVertex);
    cudaMalloc(&dev_bufVertex, vertCount * sizeof(VertexIn));
    cudaMemcpy(dev_bufVertex, bufVertex, vertCount * sizeof(VertexIn), cudaMemcpyHostToDevice);

	cudaFree(dev_bufVertexOut);
	cudaMalloc(&dev_bufVertexOut, vertOutCount * sizeof(VertexOut));

	cudaFree(dev_bufIdxOut);
	cudaMalloc((void**)&dev_bufIdxOut, vertOutCount * sizeof(int));

	cudaFree(dev_primitives);
	cudaMalloc(&dev_primitives, primCount * sizeof(Triangle));
	cudaMemset(dev_primitives, 0, primCount * sizeof(Triangle));

	cudaFree(dev_depthbuffer);
	cudaMalloc(&dev_depthbuffer, fragCount * sizeof(Fragment));
	cudaMemset(dev_depthbuffer, 0, fragCount * sizeof(Fragment));

	cudaFree(dev_framebuffer);
	cudaMalloc(&dev_framebuffer, width * height * sizeof(glm::vec3));

    checkCUDAError("rasterizeSetBuffers");
}

__global__ void kernShadeVerticesInstances(int n, int num_instances, VertexOut* vs_output, int* vs_output_idx, VertexIn* vs_input, int* vs_input_idx, glm::mat4* Mpvms, glm::mat3* Mms){
	// n is the number of in vertices
	// TODO: Can parallelize this if we do thread per output index instead of thread per input index
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < n){
		glm::mat4 Mpvm;
		glm::vec4 new_pos;
		for (int i = 0; i < num_instances; i++){
			// Model-view-perspective transform for positions
			Mpvm = Mpvms[i];

			new_pos = Mpvm * glm::vec4(vs_input[index].pos, 1.0f);
			vs_output[index + i*n].ndc_pos = glm::vec3(new_pos / new_pos.w);
			vs_output[index + i*n].nor = glm::normalize(vs_input[index].nor * Mms[i]);
			vs_output[index + i*n].col = vs_input[index].col;
			vs_output_idx[index + i*n] = vs_input_idx[index] + i*n;
		}
	}
}

__global__ void kernShadeVertices(int n, VertexOut* vs_output, VertexIn* vs_input, glm::mat4 Mpvm, glm::mat3 Mm){
	// Mm is the 3x3 rotation matrix computed with intervse transpose of the Mmodel matrix, for use to rotate normal vectors
	int index = (blockIdx.x*blockDim.x) + threadIdx.x;

	if (index < n){
		vs_output[index].pos = vs_input[index].pos;
		glm::vec4 new_pos = Mpvm * glm::vec4(vs_input[index].pos, 1.0f);
		vs_output[index].ndc_pos = glm::vec3(new_pos / new_pos.w);
		vs_output[index].nor = vs_input[index].nor * Mm;
		vs_output[index].col = vs_input[index].col;
	}
}

__global__ void kernShadeGeometries(int n, VertexOut* out_vertices, int* idx, VertexOut* in_vertices){
	int index = (blockIdx.x*blockDim.x) + threadIdx.x;

	if (index < n){
		VertexOut vi = in_vertices[index];
		idx[index * 3] = 3*index;
		idx[index * 3 + 1] = 3*index + 1;
		idx[index * 3 + 2] = 3*index + 2;
		out_vertices[index * 3].ndc_pos = vi.ndc_pos;
		out_vertices[index * 3].col = vi.col;
		out_vertices[index * 3].pos = vi.pos;
		out_vertices[index * 3].nor = vi.nor;
		out_vertices[index * 3 + 1].ndc_pos = vi.ndc_pos + glm::vec3(0.01,0.0,0.0);
		out_vertices[index * 3 + 1].col = vi.col;
		out_vertices[index * 3 + 1].pos = vi.pos;
		out_vertices[index * 3 + 1].nor = vi.nor;
		out_vertices[index * 3 + 2].ndc_pos = vi.ndc_pos + glm::vec3(0.0, 0.01, 0.0);
		out_vertices[index * 3 + 2].col = vi.col;
		out_vertices[index * 3 + 2].pos = vi.pos;
		out_vertices[index * 3 + 2].nor = vi.nor;
	}
}

__global__ void kernAssemblePrimitives(int n, Triangle* primitives, VertexOut* vs_output, int* idx){
	int index = (blockIdx.x*blockDim.x) + threadIdx.x;

	if (index < n){
		int idx0 = idx[3 * index + 0];
		int idx1 = idx[3 * index + 1];
		int idx2 = idx[3 * index + 2];
		primitives[index].v[0] = vs_output[idx0];
		primitives[index].v[1] = vs_output[idx1];
		primitives[index].v[2] = vs_output[idx2];
		primitives[index].ndc_pos[0] = vs_output[idx0].ndc_pos;
		primitives[index].ndc_pos[1] = vs_output[idx1].ndc_pos;
		primitives[index].ndc_pos[2] = vs_output[idx2].ndc_pos;
		primitives[index].v[0].col = glm::vec3(1.0, 0.0, 0.0);
		primitives[index].v[1].col = glm::vec3(1.0, 0.0, 0.0);
		primitives[index].v[2].col = glm::vec3(1.0, 0.0, 0.0);
	}
}

// Each thread is responsible for rasterizing a single triangle
__global__ void kernRasterize(int n, Cam cam, Fragment* fs_input, Triangle* primitives){
	int index = (blockIdx.x*blockDim.x) + threadIdx.x;

	if (index < n){
		
		Triangle prim = primitives[index];

		AABB aabb = getAABBForTriangle(primitives[index].ndc_pos);
		glm::vec3 bary;
		glm::vec2 point;
		glm::vec3 points;

		// Snap i,j to nearest fragment coordinate
		int frag_width = cam.width * AA;
		int frag_height = cam.height * AA;
		float dx = 2.0f / (float)frag_width;
		float dy = 2.0f / (float)frag_height;

		float x;
		float y;

		int mini = max((int)(aabb.min.x / dx) + frag_width / 2 - 2, 0);
		int minj = max((int)(aabb.min.y / dy) + frag_height / 2 - 2, 0);
		int maxi = min((int)(aabb.max.x / dx) + frag_width / 2 + 2, frag_width-1);
		int maxj = min((int)(aabb.max.y / dy) + frag_height / 2 + 2, frag_height-1);

		float depth;
		int fixed_depth;
		int ind;

		// Iterate through fragment coordinates
		for (int j = minj; j < maxj; j++){
			for (int i = mini; i < maxi; i++){

				ind = i + j * frag_width;
				
				// Get the NDC coordinate
				x = dx*i - dx*frag_width/2.0f + dx/2.0f;
				y = dy*j - dy*frag_height/2.0f + dx/2.0f;

				point[0] = x;
				point[1] = y;

				bary = calculateBarycentricCoordinate(primitives[index].ndc_pos, point);

				if (isBarycentricCoordInBounds(bary)){
					depth = -getZAtCoordinate(bary, prim.ndc_pos);
					fixed_depth = (int)(depth * INT_MAX);

					int old = atomicMin(&fs_input[ind].fixed_depth, fixed_depth);

					if (fs_input[ind].fixed_depth == fixed_depth){
						fs_input[ind].depth = depth;
						fs_input[ind].color = bary.x * prim.v[0].col + bary.y * prim.v[1].col + bary.z * prim.v[2].col; //glm::vec3(1.0, 0.0, 0.0);// prim.v[0].col;
						fs_input[ind].norm = bary.x * prim.v[0].nor + bary.y * prim.v[1].nor + bary.z * prim.v[2].nor;
						fs_input[ind].pos = bary.x * prim.v[0].pos + bary.y * prim.v[1].pos + bary.z * prim.v[2].pos;
						fs_input[ind].ndc_pos = bary.x * prim.v[0].ndc_pos + bary.y * prim.v[1].ndc_pos + bary.z * prim.v[2].ndc_pos;
						//fs_input[ind].color = fs_input[ind].norm;
					}
				}
				
			}
		}
	}
}

__global__ void kernShadeFragments(int n, Fragment* fs_input, Light light){
	int index = (blockIdx.x*blockDim.x) + threadIdx.x;

	if (index < n){
		if (fs_input[index].color != glm::vec3(0.0)){
			glm::vec3 light_ray = glm::normalize(fs_input[index].pos - light.pos);
			fs_input[index].color = fs_input[index].color * abs((glm::dot(glm::normalize(fs_input[index].norm), light_ray)));
		}
	}
}

void resetRasterize(){
	cudaMemset(dev_depthbuffer, 0, fragCount * sizeof(Fragment));
	initDepths<<<numFragBlocks, MAX_THREADS>>>(fragCount, dev_depthbuffer);

	cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));
	checkCUDAError("resetBuffers");
}

/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo, Cam cam) {
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
                      (height - 1) / blockSize2d.y + 1);

	resetRasterize();

	//Mmod = glm::mat4(1.0f);
	Mview = glm::lookAt(cam.pos, cam.focus, cam.up);
	Mproj = glm::perspective(cam.fovy, cam.aspect, cam.zNear, cam.zFar);



	for (int i = 0; i < NUM_INSTANCES; i++){
		Mmod = glm::mat4(1.0);
		Mmod = glm::translate(Mmod, glm::vec3(i*0.5f,0.0f,i*-1.0f));
		Mmod = glm::rotate(Mmod, i*3.14f/8.0f, glm::vec3(0.0,1.0,0.0));
		Mms[i] = glm::inverseTranspose(glm::mat3(Mmod));
		Mpvms[i] = Mproj * Mview * Mmod;
	}


	cudaMalloc((void**)&dev_Mpvms, NUM_INSTANCES*sizeof(glm::mat4));
	cudaMemcpy(dev_Mpvms, Mpvms, NUM_INSTANCES*sizeof(glm::mat4), cudaMemcpyHostToDevice);
	cudaMalloc((void**)&dev_Mms, NUM_INSTANCES*sizeof(glm::mat3));
	cudaMemcpy(dev_Mms, Mms, NUM_INSTANCES*sizeof(glm::mat3), cudaMemcpyHostToDevice);

	// Vertex Shading
	kernShadeVerticesInstances<<<numVertBlocks, MAX_THREADS>>>(vertCount, NUM_INSTANCES, dev_bufVertexOut, dev_bufIdxOut, dev_bufVertex, dev_bufIdx, dev_Mpvms, dev_Mms);
	//kernShadeVertices<<<numVertBlocks, MAX_THREADS>>>(vertCount, dev_bufVertexOut, dev_bufVertex, Mpvm);
	checkCUDAError("shadeVertices");
	cudaFree(dev_Mpvms);
	cudaFree(dev_Mms);

	// Primitive Assembly
	kernAssemblePrimitives<<<numPrimBlocks, MAX_THREADS>>>(primCount, dev_primitives, dev_bufVertexOut, dev_bufIdxOut);
	checkCUDAError("assemblePrimitives");

	// Rasterization
	kernRasterize<<<numPrimBlocks, MAX_THREADS>>>(primCount, cam, dev_depthbuffer, dev_primitives);
	checkCUDAError("rasterizePrimitives");

	// Fragment shading
	kernShadeFragments<<<numFragBlocks, MAX_THREADS>>>(fragCount, dev_depthbuffer, light);
	checkCUDAError("shadeFragments");

    // Copy depthbuffer colors into framebuffer
    render<<<blockCount2d, blockSize2d>>>(width, height, dev_depthbuffer, dev_framebuffer);

    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("rasterize");

	iter += 1;
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {
    cudaFree(dev_bufIdx);
    dev_bufIdx = NULL;

	cudaFree(dev_bufIdxOut);
	dev_bufIdxOut = NULL;

    cudaFree(dev_bufVertex);
    dev_bufVertex = NULL;

	cudaFree(dev_bufVertexOut);
	dev_bufVertexOut = NULL;

    cudaFree(dev_primitives);
    dev_primitives = NULL;

    cudaFree(dev_depthbuffer);
    dev_depthbuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

    checkCUDAError("rasterizeFree");
}
