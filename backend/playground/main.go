package main

import (
	"fmt"
	"math"
)

const Projectname string = "Go Experiment"

var List []string = []string{"Go", "Experiment", "Playground"}

var NumList []int = []int{1, 2, 3, 4, 5}

func main() {
	fmt.Println("Welcome to", Projectname)
	fmt.Println(math.Pi)

	for _, item := range List {
		if item == "Experiment" {
			fmt.Println("Found:", item)
		} else {
			fmt.Println("Other item:", item)
		}
	}

	for _, item := range NumList {
		if item%2 == 0 {
			fmt.Println("Even number:", item)
		} else {
			fmt.Println("Odd number:", item)
		}
	}
}
