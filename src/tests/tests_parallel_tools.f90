
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
! Unit tests for parallel (MPI) tools.
!
! Vitaliy Ogarko, UWA, CET, Australia, 2015-2016.
!===============================================================================================
module tests_parallel_tools

  use global_typedefs
  use ftnunit

  use parallel_tools

  implicit none

  private

  public :: test_get_number_elements_on_other_cpus
  public :: test_get_total_number_elements
  public :: test_get_full_array
  public :: test_get_full_array_in_place

contains

!=============================================================================================
! Testing get_number_elements_on_other_cpus().
!=============================================================================================
subroutine test_get_number_elements_on_other_cpus(myrank, nbproc)
  integer, intent(in) :: myrank, nbproc

  type(t_parallel_tools) :: pt
  integer :: nelements_at_cpu(nbproc)
  integer :: i, nelements

  nelements = 5 * (myrank + 1) + 3

  nelements_at_cpu = pt%get_number_elements_on_other_cpus(nelements, myrank, nbproc)

  do i = 1, nbproc
    call assert_equal_int(nelements_at_cpu(i), 5 * i + 3, "test_get_number_elements_on_other_cpus failed.")
  enddo

end subroutine test_get_number_elements_on_other_cpus

!=============================================================================================
! Testing get_total_number_elements().
!=============================================================================================
subroutine test_get_total_number_elements(myrank, nbproc)
  integer, intent(in) :: myrank, nbproc

  type(t_parallel_tools) :: pt
  integer :: nelements, nelements_total

  ! Set different number of elements on every CPU, as:
  ! CPU 1: 1 element,
  ! CPU 2: 2 elements,
  ! CPU 3: 3 elements, etc.
  nelements = myrank + 1

  nelements_total = pt%get_total_number_elements(nelements, myrank, nbproc)

  call assert_equal_int(nelements_total, (nbproc + 1) * nbproc / 2, "Wrong nelements_total in test_get_total_number_elements.")

end subroutine test_get_total_number_elements

!=============================================================================================
! Testing get_full_array().
!=============================================================================================
subroutine test_get_full_array(myrank, nbproc)
  integer, intent(in) :: myrank, nbproc

  integer :: nelements, nelements_total
  real(kind=CUSTOM_REAL), allocatable :: model(:)
  real(kind=CUSTOM_REAL), allocatable :: model_all(:)
  type(t_parallel_tools) :: pt
  integer :: i

  ! Set different number of elements on every CPU, as:
  ! CPU 1: 1 element,
  ! CPU 2: 2 elements,
  ! CPU 3: 3 elements, etc.
  nelements = myrank + 1

  nelements_total = pt%get_total_number_elements(nelements, myrank, nbproc)

  allocate(model(nelements))
  allocate(model_all(nelements_total))

  ! Form a model vector (1, 2, 3, 4, ...).
  ! To do this, sum nelements on the lower ranks,
  ! assuming the above relation nelements(myrank) = myrank + 1.
  do i = 1, nelements
    model(i) = dble((myrank + 1) * myrank / 2 + i)
  enddo

  call pt%get_full_array(model, nelements, model_all, .true., myrank, nbproc)

  ! Check the result.
  do i = 1, nelements_total
    call assert_equal_int(int(model_all(i)), i, "model_all(i) /= i in test_get_full_array.")
  enddo

  deallocate(model)
  deallocate(model_all)

end subroutine test_get_full_array

!=============================================================================================
! Testing get_full_array_in_place().
!=============================================================================================
subroutine test_get_full_array_in_place(myrank, nbproc)
  integer, intent(in) :: myrank, nbproc

  integer :: nelements, nelements_total
  real(kind=CUSTOM_REAL), allocatable :: model_all(:)
  type(t_parallel_tools) :: pt
  integer :: i

  ! Set different number of elements on every CPU, as:
  ! CPU 1: 1 element,
  ! CPU 2: 2 elements,
  ! CPU 3: 3 elements, etc.
  nelements = myrank + 1

  nelements_total = pt%get_total_number_elements(nelements, myrank, nbproc)

  allocate(model_all(nelements_total))

  ! Form a model vector (1, 2, 3, 4, ...).
  ! To do this, sum nelements on the lower ranks,
  ! assuming the above relation nelements(myrank) = myrank + 1.
  do i = 1, nelements
    model_all(i) = dble((myrank + 1) * myrank / 2 + i)
  enddo

  call pt%get_full_array_in_place(nelements, model_all, .true., myrank, nbproc)

  ! Check the result.
  do i = 1, nelements_total
    call assert_equal_int(int(model_all(i)), i, "model_all(i) /= i in test_get_full_array_in_place.")
  enddo

  deallocate(model_all)

end subroutine test_get_full_array_in_place

end module tests_parallel_tools