"""
Simle integrators for the radiative transfer equation

Author: Matthew Turk <matthewturk@gmail.com>
Affiliation: KIPAC/SLAC/Stanford
Homepage: http://yt.enzotools.org/
License:
  Copyright (C) 2009 Matthew Turk.  All Rights Reserved.

  This file is part of yt.

  yt is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
"""

import numpy as np
cimport numpy as np
cimport cython
from stdlib cimport malloc, free, abs

cdef extern from "math.h":
    double exp(double x)
    float expf(float x)
    double floor(double x)
    double ceil(double x)

cdef extern from "FixedInterpolator.h":
    np.float64_t fast_interpolate(
                    np.float64_t left_edge[3], np.float64_t dds[3],
                    int *ds, int ci[3], np.float64_t cp[3], np.float64_t *data)
    inline void eval_shells(int nshells, np.float64_t dv,
                    np.float64_t *shells, np.float64_t rgba[4], np.float64_t dt)

cdef class PartitionedGrid:
    cdef public object my_data
    cdef public object LeftEdge
    cdef public object RightEdge
    cdef np.float64_t *data
    cdef np.float64_t left_edge[3]
    cdef np.float64_t right_edge[3]
    cdef np.float64_t dds[3]
    cdef int dims[3]

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def __cinit__(self,
                  np.ndarray[np.float64_t, ndim=3] data,
                  np.ndarray[np.float64_t, ndim=1] left_edge,
                  np.ndarray[np.float64_t, ndim=1] right_edge,
                  np.ndarray[np.int64_t, ndim=1] dims):
        # The data is likely brought in via a slice, so we copy it
        cdef int i
        self.LeftEdge = left_edge
        self.RightEdge = right_edge
        cdef np.ndarray[np.float64_t, ndim=3] tdata = data.copy()
        self.my_data = tdata
        self.data = <np.float64_t *> (tdata.data)
        
        for i in range(3):
            self.left_edge[i] = left_edge[i]
            self.right_edge[i] = right_edge[i]
            self.dims[i] = dims[i]
            self.dds[i] = (self.right_edge[i] - self.left_edge[i])/dims[i]

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def cast_plane(self, np.ndarray[np.float64_t, ndim=3] vp_pos,
                         np.ndarray[np.float64_t, ndim=1] vp_dir,
                         np.ndarray[np.float64_t, ndim=2] shells,
                         np.ndarray[np.float64_t, ndim=3] image_plane,
                         np.float64_t dt,
                         np.float64_t xp0, np.float64_t xp1,
                         np.float64_t yp0, np.float64_t yp1,
                         np.ndarray[np.float64_t, ndim=1] xa_vec,
                         np.ndarray[np.float64_t, ndim=1] ya_vec,
                         np.ndarray[np.float64_t, ndim=1] centera):
        # This routine will iterate over all of the vectors and cast each in
        # turn.  Might benefit from a more sophisticated intersection check,
        # like http://courses.csusm.edu/cs697exz/ray_box.htm
        cdef int vi, vj, hit, i, i0, j0, ni, nj, nn
        cdef int nv = vp_pos.shape[0]
        cdef int nshells = shells.shape[0]
        cdef np.float64_t v_pos[3], v_dir[3], rgba[4], extrema[4]
        cdef np.float64_t x_vec[3], y_vec[3], center[3]
        cdef np.float64_t pdx = (xp1-xp0)/nv, pdy = (yp1-yp0)/nv
        for i in range(3):
            v_dir[i] = vp_dir[i]
            x_vec[i] = xa_vec[i]
            y_vec[i] = ya_vec[i]
            center[i] = centera[i]
        extrema[0] = extrema[2] = 1e300
        extrema[1] = extrema[3] = -1e300
        self.calculate_extent(x_vec, y_vec, center, extrema)
        i0 = <int> floor((extrema[0] - xp0)/pdx)
        j0 = <int> floor((extrema[2] - yp0)/pdy)
        i1 = i0 + <int> ceil((extrema[1] - extrema[0])/pdx)
        j1 = j0 + <int> ceil((extrema[3] - extrema[2])/pdy)
        if i0 < 0: i0 = 0
        elif i0 > nv: i0 = nv
        if j0 < 0: j0 = 0
        elif j0 > nv: j0 = nv
        if i1 < 0: i1 = 0
        elif i1 > nv: i1 = nv
        if j1 < 0: j1 = 0
        elif j1 > nv: j1 = nv
        hit = 0
        i0 = j0 = 0
        i1 = j1 = nv
        for vi in range(i0,i1):
            for vj in range(j0,j1):
            # Copy into temporary space
                for i in range(3): v_pos[i] = vp_pos[vi,vj,i]
                for i in range(4): rgba[i] = image_plane[vi,vj,i]
                if dt > 0:
                    hit += self.sample_ray(v_pos, v_dir, nshells, rgba,
                                             <np.float64_t *> shells.data, dt)
                else:
                    hit += self.integrate_ray(v_pos, v_dir, nshells, rgba,
                                             <np.float64_t *> shells.data)
                for i in range(4): image_plane[vi,vj,i] = rgba[i] 
        return hit

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef void calculate_extent(self,
                               np.float64_t x_vec[3],
                               np.float64_t y_vec[3],
                               np.float64_t center[3],
                               np.float64_t extrema[4]):
        # We do this for all eight corners
        cdef np.float64_t *edges[2], temp
        edges[0] = self.left_edge
        edges[1] = self.right_edge
        cdef int i, j, k
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    temp  = edges[i][0] * x_vec[0]
                    temp += edges[j][1] * x_vec[1]
                    temp += edges[k][2] * x_vec[2]
                    if temp < extrema[0]: extrema[0] = temp
                    if temp > extrema[1]: extrema[1] = temp
                    temp  = edges[i][0] * y_vec[0]
                    temp += edges[j][1] * y_vec[1]
                    temp += edges[k][2] * y_vec[2]
                    if temp < extrema[2]: extrema[2] = temp
                    if temp > extrema[3]: extrema[3] = temp
        #print extrema[0], extrema[1], extrema[2], extrema[3]

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef int integrate_ray(self, np.float64_t v_pos[3],
                                 np.float64_t v_dir[3],
                                 int nshells,
                                 np.float64_t rgba[4],
                                 np.float64_t *shells):
        cdef int cur_ind[3], step[3], x, y, i, n, flat_ind, hit
        cdef np.float64_t intersect_t = 1.0
        cdef np.float64_t intersect[3], tmax[3], tdelta[3]
        cdef np.float64_t enter_t, dist, alpha, dt
        cdef np.float64_t tr, tl, temp_x, temp_y, dv
        for i in range(3):
            if (v_dir[i] < 0):
                step[i] = -1
            else:
                step[i] = 1
            x = (i+1) % 3
            y = (i+2) % 3
            tl = (self.left_edge[i] - v_pos[i])/v_dir[i]
            tr = (self.right_edge[i] - v_pos[i])/v_dir[i]
            temp_x = (v_pos[x] + tl*v_dir[x])
            temp_y = (v_pos[y] + tl*v_dir[y])
            if self.left_edge[x] <= temp_x and temp_x <= self.right_edge[x] and \
               self.left_edge[y] <= temp_y and temp_y <= self.right_edge[y] and \
               0.0 <= tl and tl < intersect_t:
                intersect_t = tl
            temp_x = (v_pos[x] + tr*v_dir[x])
            temp_y = (v_pos[y] + tr*v_dir[y])
            if self.left_edge[x] <= temp_x and temp_x <= self.right_edge[x] and \
               self.left_edge[y] <= temp_y and temp_y <= self.right_edge[y] and \
               0.0 <= tr and tr < intersect_t:
                intersect_t = tr
        if self.left_edge[0] <= v_pos[0] and v_pos[0] <= self.right_edge[0] and \
           self.left_edge[1] <= v_pos[1] and v_pos[1] <= self.right_edge[1] and \
           self.left_edge[2] <= v_pos[2] and v_pos[2] <= self.right_edge[2]:
            intersect_t = 0.0
        if not ((0.0 <= intersect_t) and (intersect_t < 1.0)):
            return 0
        for i in range(3):
            intersect[i] = v_pos[i] + intersect_t * v_dir[i]
            cur_ind[i] = <int> floor((intersect[i] + 1e-8*self.dds[i] -
                                      self.left_edge[i])/self.dds[i])
            tmax[i] = (((cur_ind[i]+step[i])*self.dds[i])+
                        self.left_edge[i]-v_pos[i])/v_dir[i]
            if cur_ind[i] == self.dims[i] and step[i] < 0:
                cur_ind[i] = self.dims[i] - 1
            if cur_ind[i] < 0 or cur_ind[i] >= self.dims[i]:
                return 0
            if step[i] > 0:
                tmax[i] = (((cur_ind[i]+1)*self.dds[i])
                            +self.left_edge[i]-v_pos[i])/v_dir[i]
            if step[i] < 0:
                tmax[i] = (((cur_ind[i]+0)*self.dds[i])
                            +self.left_edge[i]-v_pos[i])/v_dir[i]
            tdelta[i] = (self.dds[i]/v_dir[i])
            if tdelta[i] < 0:
                tdelta[i] *= -1
        enter_t = intersect_t
        while 1:
            if (not (0 <= cur_ind[0] < self.dims[0])) or \
               (not (0 <= cur_ind[1] < self.dims[1])) or \
               (not (0 <= cur_ind[2] < self.dims[2])):
                break
            hit += 1
            flat_ind = (((cur_ind[2])*self.dims[1]+(cur_ind[1]))*self.dims[0]+cur_ind[0])
            dv = self.data[flat_ind]
            # Do our transfer here
            eval_shells(nshells, dv, shells, rgba, dt)
            if (tmax[0] > 1.0) and (tmax[1] > 1.0) and (tmax[2] > 1.0):
                dt = 1.0 - enter_t
                rgba[2] += dt
                break
            if tmax[0] < tmax[1]:
                if tmax[0] < tmax[2]:
                    dt = tmax[0] - enter_t
                    enter_t = tmax[0]
                    tmax[0] += tdelta[0]
                    cur_ind[0] += step[0]
                else:
                    dt = tmax[2] - enter_t
                    enter_t = tmax[2]
                    tmax[2] += tdelta[2]
                    cur_ind[2] += step[2]
            else:
                if tmax[1] < tmax[2]:
                    dt = tmax[1] - enter_t
                    enter_t = tmax[1]
                    tmax[1] += tdelta[1]
                    cur_ind[1] += step[1]
                else:
                    dt = tmax[2] - enter_t
                    enter_t = tmax[2]
                    tmax[2] += tdelta[2]
                    cur_ind[2] += step[2]
            rgba[2] += dt
        return hit

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef int sample_ray(self, np.float64_t v_pos[3],
                              np.float64_t v_dir[3],
                              int nshells,
                              np.float64_t rgba[4],
                              np.float64_t *shells,
                              np.float64_t dt):
        cdef int cur_ind[3], x, y, i, n, flat_ind, hit
        cdef np.float64_t cur_pos[3], intersect_t = 1.0
        cdef np.float64_t dist, alpha, t
        cdef np.float64_t tr, tl, temp_x, temp_y, dv
        for i in range(3):
            x = (i+1) % 3
            y = (i+2) % 3
            tl = (self.left_edge[i] - v_pos[i])/v_dir[i]
            tr = (self.right_edge[i] - v_pos[i])/v_dir[i]
            if tl < 0.0 and tr < 0.0: return 0
            if tl > 1.0 and tr > 1.0: return 0
            temp_x = (v_pos[x] + tl*v_dir[x])
            temp_y = (v_pos[y] + tl*v_dir[y])
            if (self.left_edge[x] <= temp_x <= self.right_edge[x]) and \
               (self.left_edge[y] <= temp_y <= self.right_edge[y]) and \
               (0.0 <= tl < intersect_t):
                intersect_t = tl
            temp_x = (v_pos[x] + tr*v_dir[x])
            temp_y = (v_pos[y] + tr*v_dir[y])
            if (self.left_edge[x] <= temp_x <= self.right_edge[x]) and \
               (self.left_edge[y] <= temp_y <= self.right_edge[y]) and \
               (0.0 <= tr < intersect_t):
                intersect_t = tr
        if self.left_edge[0] <= v_pos[0] and v_pos[0] <= self.right_edge[0] and \
           self.left_edge[1] <= v_pos[1] and v_pos[1] <= self.right_edge[1] and \
           self.left_edge[2] <= v_pos[2] and v_pos[2] <= self.right_edge[2]:
            intersect_t = 0.0
        if not ((0.0 <= intersect_t) and (intersect_t < 1.0)):
            return 0
        for i in range(3):
            cur_pos[i] =  v_pos[i] + intersect_t * v_dir[i]
            cur_ind[i] = <int> floor((cur_pos[i] + 1e-8*self.dds[i] -
                                      self.left_edge[i])/self.dds[i])
            if cur_ind[i] == self.dims[i] and v_dir[i] < 0:
                cur_ind[i] = self.dims[i] - 1
            if cur_ind[i] < 0 or cur_ind[i] >= self.dims[i]:
                return 0
        t = ceil(intersect_t / dt) * dt
        while 1:
            if rgba[3] < 1e-6: break
            for i in range(3):
                cur_pos[i] = v_pos[i] + t*v_dir[i]
                cur_ind[i] = <int> floor((cur_pos[i] - self.left_edge[i])/self.dds[i])
            if (not (0 <= cur_ind[0] < self.dims[0])) or \
               (not (0 <= cur_ind[1] < self.dims[1])) or \
               (not (0 <= cur_ind[2] < self.dims[2])):
                break
            hit += 1
            dv = fast_interpolate(self.left_edge, self.dds, self.dims,
                                  cur_ind, cur_pos, self.data)
            # Do our transfer here
            eval_shells(nshells, dv, shells, rgba, dt)
            t += dt
        return hit