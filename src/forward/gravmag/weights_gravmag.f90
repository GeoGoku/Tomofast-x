
!========================================================================
!
!                    T O M O F A S T X  Version 1.0
!                  ----------------------------------
!
!              Main authors: Vitaliy Ogarko, Roland Martin,
!                   Jeremie Giraud, Dimitri Komatitsch.
! CNRS, France, and University of Western Australia.
! (c) CNRS, France, and University of Western Australia. January 2018
!
! This software is a computer program whose purpose is to perform
! capacitance, gravity, magnetic, or joint gravity and magnetic tomography.
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 2 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
! The full text of the license is available in file "LICENSE".
!
!========================================================================

!===============================================================================================
! A class to calculate weights for sensitivity matrix and damping.
!
! Vitaliy Ogarko, UWA, CET, Australia, 2015-2016.
!===============================================================================================
module weights_gravmag

  use global_typedefs
  use parameters_gravmag
  use parameters_inversion
  use inversion_arrays
  use grid
  use mpi_tools, only: exit_MPI

  implicit none

  private

  type, public :: t_weights
    private

  contains
    private

    procedure, public, nopass :: calculate => weights_calculate

    procedure, private, nopass :: calculate_depth_weight
    procedure, private, nopass :: calculate_depth_weight_sensit
    procedure, private, nopass :: normalize_depth_weight

  end type t_weights

contains

!===================================================================================
! Calculates the weights for inversion.
!===================================================================================
subroutine weights_calculate(par, iarr, xdata, ydata, myrank, nbproc)
  class(t_parameters_base), intent(in) :: par
  real(kind=CUSTOM_REAL), intent(in) :: xdata(:), ydata(:)
  integer, intent(in) :: myrank, nbproc
  type(t_inversion_arrays), intent(inout) :: iarr
  integer :: i, ierr
  real(kind=CUSTOM_REAL) :: Si
  real(kind=CUSTOM_REAL), allocatable :: sensit_column(:)

  !--------------------------------------------------------------------------------
  ! Calculate the damping weight as the normalized depth weight.
  !--------------------------------------------------------------------------------

  if (par%depth_weighting_type == 1) then

    ! Method I: use empirical function 1/(z+z0)**(beta/2).
    do i = 1, par%nelements
      iarr%damping_weight(i) = calculate_depth_weight(iarr%model%grid, par%beta, par%Z0, i, myrank)
    enddo

  else if (par%depth_weighting_type == 2) then

    if (myrank == 0) print *, 'Error: Not supported case!'
    stop

    ! Method II: use only sensitivity values directly below the data (i.e., z-column).
    ! Calculate damping weight using sensitivity kernel.
    call calculate_depth_weight_sensit(iarr%model%grid, xdata, ydata, iarr%sensitivity, iarr%damping_weight, &
                                       iarr%nelements, iarr%ndata, myrank, nbproc)

  else if (par%depth_weighting_type == 3) then

    allocate(sensit_column(iarr%ndata), source=0._CUSTOM_REAL, stat=ierr)

    ! Method III: scale model by the integrated sensitivities, see
    ! [1] (!!) Yaoguo Li, Douglas W. Oldenburg., Joint inversion of surface and three-component borehole magnetic data, 2000.
    ! [2] Portniaguine and Zhdanov (2002).
    ! For discussion on different weightings see also:
    !   [1] M. Pilkington, Geophysics, vol. 74, no. 1, 2009.
    !   [2] F. Cella and M. Fedi, Geophys. Prospecting, 2012, 60, 313-336.
    do i = 1, par%nelements
      call iarr%matrix_sensit%get_column(i, sensit_column)

      ! Integrated sensitivity matrix (diagonal).
      Si = norm2(sensit_column)

      iarr%damping_weight(i) = sqrt(Si)

      ! print *, i,  iarr%damping_weight(i)
    enddo

    deallocate(sensit_column)

  else
    call exit_MPI("Unknown depth weighting type!", myrank, 0)
  endif

  ! Normalize the depth weight.
  call normalize_depth_weight(iarr%damping_weight, myrank, nbproc)

  !--------------------------------------------------------------------------------
  ! Calculate the matrix column weight.
  !--------------------------------------------------------------------------------

  ! This condition essentially leads to the system:
  !
  ! | S W^{-1} | d(Wm)
  ! |    I     |
  !
  do i = 1, par%nelements
    if (iarr%damping_weight(i) /= 0.d0) then
      iarr%column_weight(i) = 1.d0 / iarr%damping_weight(i)
    else
      !iarr%column_weight(i) = 1.d0
      call exit_MPI("Zero damping weight! Exiting.", myrank, 0)
    endif
  enddo

  ! This condition essentially leads to the system:
  !
  ! | S | dm
  ! | W |
  !iarr%column_weight = 1._CUSTOM_REAL

end subroutine weights_calculate

!===================================================================================
! Calculates the depth weight for a pixel using empirical function.
!===================================================================================
function calculate_depth_weight(grid, beta, Z0, i, myrank) result(weight)
  type(t_grid), intent(in) :: grid
  real(kind=CUSTOM_REAL), intent(in) :: beta
  integer, intent(in) :: i, myrank
  real(kind=CUSTOM_REAL), intent(in) :: Z0
  real(kind=CUSTOM_REAL) :: weight

  real(kind=CUSTOM_REAL) :: depth

  ! Depth to the middle of the voxel.
  depth = grid%get_Z_cell_center(i)

  if (depth + Z0 > 0.d0) then
    weight = (depth + Z0)**(- beta / 2.d0)
  else
    print *, depth
    print *, Z0
    call exit_MPI("Error: non-positive depth in calculate_depth_weight!", myrank, 0)
  endif

end function calculate_depth_weight

!========================================================================================
! Calculates the damping weight using sensitivity kernel below the data location.
!========================================================================================
subroutine calculate_depth_weight_sensit(grid, xdata, ydata, sensit, damping_weight, &
                                         nelements, ndata, myrank, nbproc)
  type(t_grid), intent(in) :: grid
  real(kind=CUSTOM_REAL), intent(in) :: xdata(:), ydata(:)
  real(kind=CUSTOM_REAL), intent(in) :: sensit(:, :)
  integer, intent(in) :: nelements, ndata, myrank, nbproc
  real(kind=CUSTOM_REAL), intent(out) :: damping_weight(:)

  integer :: p, i, idata

  ! Loop over local elements.
  do p = 1, nelements

    ! Search for data corresponding to the element:
    !   the data (X, Y) position is inside a grid-cell (X, Y) position.
    idata = 0
    do i = 1, ndata
      if (xdata(i) >= grid%X1(p) .and. xdata(i) <= grid%X2(p) .and. &
          ydata(i) >= grid%Y1(p) .and. ydata(i) <= grid%Y2(p)) then
        idata = i
        exit
      endif
    enddo

    if (idata == 0) then
      print *, 'Error: Not found data corresponding to the pixel p =', p
      stop
      return
    endif

    if (sensit(p, idata) >= 0) then
      damping_weight(p) = sqrt(sensit(p, idata))
    else
      print *, 'Error: Negative sensitivity, cannot calculate damping weight!', sensit(p, idata)
      stop
    endif
  enddo

end subroutine calculate_depth_weight_sensit

!===================================================================================
! Normalizes the depth weight.
!===================================================================================
subroutine normalize_depth_weight(damping_weight, myrank, nbproc)
  integer, intent(in) :: myrank, nbproc

  real(kind=CUSTOM_REAL), intent(inout) :: damping_weight(:)

  integer :: ierr
  real(kind=CUSTOM_REAL) :: norm, norm_glob

  ! Find the maximum value in the depth weight array.
  norm = maxval(damping_weight)
  if (nbproc > 1) then
    call mpi_allreduce(norm, norm_glob, 1, CUSTOM_MPI_TYPE, MPI_MAX, MPI_COMM_WORLD, ierr)
    norm = norm_glob
  endif

  if (norm /= 0) then
    ! Normalize.
    damping_weight = damping_weight / norm
  else
    call exit_MPI("Zero damping weight norm! Exiting.", myrank, 0)
  endif

end subroutine normalize_depth_weight

end module weights_gravmag