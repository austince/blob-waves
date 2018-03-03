
import processing.video.*;
import processing.sound.*;
import gab.opencv.*;
import java.awt.Rectangle;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/*
BLOB DETECTION: WEBCAM
Austin Cawley-Edwards, Jeff Thompson

*/

Capture webcam;              // webcam input
OpenCV cv;                   // instance of the OpenCV library
SoundFile oceanSound;        // ocean sound to play from each point
                             // Would one day love this to be spatial / positional

float minBlobArea, maxBlobArea;
float minBlobWidthHeightRatio;
float maxBlobDistanceChange; // todo, an extension on blob tracking

List<Blob> blobs = new ArrayList();    // list of blobs we know about
AtomicInteger blobId = new AtomicInteger(0); // how we give blobs ids

List<Ring> rings = new ArrayList();
AtomicInteger ringId = new AtomicInteger(0);

float detail = 0.6;      // amount of detail in the noise (0-1)
float increment = 0.002;    // how quickly to move through noise (0-1)

PImage bgImage = null; // The background to remove
int threshold = 60; // for thresholding the image

int blobSpawnAge = 200;
int maxRingAge = 600;

boolean debug = true;
boolean production = false;

boolean resetBackground = true; // always reset on first run

void setup() {
    size(1280, 720); // for local
    // size(displayWidth, displayHeight); // for production

    colorMode(HSB);

    setupLogger();

    logDisplayInfo();
    pixelDensity(displayDensity());


    // create an instance of the OpenCV library
    cv = new OpenCV(this, width, height);

    // Set the noise for the ring growth
    noiseDetail(8, detail);

    // For blob filtering
    minBlobArea = (width * height) / 512;
    maxBlobArea = (width * height) / 256;
    minBlobWidthHeightRatio = 0.4; // 0-1, square + circle have 1

    // not yet implemented
    maxBlobDistanceChange = (width * height) / 100; // only let the blob change by 1/100 of the area

    // https://github.com/processing/processing/issues/4601
    log("Blob MinArea", minBlobArea);
    log("Blob MaxArea", maxBlobArea);


    // start the webcam
    logCameras();
    String camId = getCameraIdBySpecsOrDefault(1280, 720, 30);
    if (camId == null) {
        log("Couldn't detect any webcams connected!");
        exit();
    }
    webcam = new Capture(this, camId);
    webcam.start();


    if (!debug) {
      oceanSound = new SoundFile(this, "ocean.mp3");
      oceanSound.loop();
    }
    // text settings (for showing the # of blobs)
    textSize(20);
    textAlign(LEFT, BOTTOM);

    colorMode(HSB, 360, 100, 100);

    noCursor();

    frameRate(30); // 60 is too much for the blob detection
}

void draw() {
  background(0, 0, 100); // white
  // Draw the blobs and the rings
  noFill();
  stroke(255,150,100);
  strokeWeight(3);

  for (Blob blob : blobs) {
    blob.update();
    if (blob.age % blobSpawnAge == 0) {
      log("Spawning ring from blob", blob.id);
      Ring ring = blob.spawnRing();
      ring.setId(ringId.getAndIncrement());
      ring.setMaxAge(maxRingAge);
      ring.setGrowAge(50);
      rings.add(ring);
    }
    blob.display();
  }

  for (int i = rings.size() - 1; i >= 0; i--) {
    Ring ring = rings.get(i);
    ring.update();

    if (ring.age >= maxRingAge) {
      log("Removing ring", ring.id);
      rings.remove(i);
    } else {
      ring.display();
    }
  }

  String fps = nf(frameRate, 0,2) + " fps";
  if (debug) {
    fill(0);
    noStroke();
    text(fps, 50,50);
  }
  logInProd(fps);


  // don't do any blob detection until a new frame of video is available
  // is available
  if (webcam.available()) {
    prepareImage();

    // To show the captured image
    // image(cv.getOutput(), 0,0);
    // image(webcam, 0,0);
    // Could improve the performance by better filtering?
    blobDetect(); // should do this in a background thread :/
  }
}

void keyPressed() {
  if (key == 'd') {
    debug = !debug;
  } else if (key == 'u') {
    // Mark the background for updating
    resetBackground = true;
  } else if (key == CODED) {
    if (keyCode == UP) {
      threshold += 5;
    } else if (keyCode == DOWN) {
      threshold -= 5;
    }
  }
}

/**
* returns true if it passes the requirements
*/
boolean filterBlob(Blob blob) {
    // filter by size
    float area = blob.getContour().area();
    if (area > maxBlobArea || area < minBlobArea) {
        return false;
    }

    Rectangle bounds = blob.getContour().getBoundingBox();
    float whRatio;
    if (bounds.width > bounds.height) {
        whRatio = (float) bounds.height / (float) bounds.width;
    } else {
        whRatio = (float) bounds.width / (float) bounds.height;
    }

    if (whRatio < minBlobWidthHeightRatio) {
        return false;
    }

    return true;
}


void prepareImage() {
  // read the webcam and load the frame into OpenCV
  webcam.read();

  cv.loadImage(webcam);

  if (bgImage == null || resetBackground) {
    log("Resetting background!");
    bgImage = cv.getSnapshot();
    resetBackground = false;
  }

  // Remove that background before it's all eroded and such!
  cv.diff(bgImage);

  // pre-process the image (adjust the threshold
  // using the mouse) and display it onscreen
  cv.threshold(threshold);
  cv.invert();    // blobs should be white, so you might have to use this
  cv.dilate();
  cv.erode();
}

/**
* Updates a blob from another and resets the resets the timer
* NOTE: Could be a class method
*/
void setBlob(Blob dest, Blob from) {
  dest.become(from);
  dest.resetTimer();
}

void addNewBlob(Blob b) {
  b.setId(blobId.getAndIncrement());
  blobs.add(b);
  // log("Found new blob:", b.id);
}

/**
* Find the next closest blob that hasn't already been matched
*/
Blob closestNotAlreadyMatched(Blob blob, List<Blob> foundBlobs) {
  Blob matchedBlob = null;
  float minDistance = width * height; // will never be greater than this
  for (Blob foundBlob: foundBlobs) {
    float dist = PVector.dist(blob.getCentroid(), foundBlob.getCentroid());
    float sizeDiff = abs(blob.getContour().area() - foundBlob.getContour().area());
    float compareDist = (1 * dist) + (0 * sizeDiff); // could weight these
    if (compareDist < minDistance && !foundBlob.matched) {
      matchedBlob = foundBlob;
      minDistance = compareDist;
    }
  }

  return matchedBlob;
}

/**
* Detect blobs with persistance
*/
void blobDetect() {
  // get the blobs and draw them
  List<Contour> contours = cv.findContours();
  List<Blob> foundBlobs = new ArrayList(); // list of filtered blobs we've found

  // Do basic filtering and transform Contour => Blob
  for (Contour contour: contours) {
      Blob convexBlob = blobFromContour(contour.getConvexHull());
      if (filterBlob(convexBlob)) {
          foundBlobs.add(convexBlob);
      }
  }

  // Remove those that contain other blobs
  for (int i = foundBlobs.size() - 1; i >= 0; i--) {
    Blob blob = foundBlobs.get(i);
    if (blob.containsAnother(foundBlobs)) {
        foundBlobs.remove(i);
    }
  }

  // Persistance!
  if (blobs.size() <= foundBlobs.size()) {
    // log("Matching blobs");
    // Same blobs detected, let's match!
    // match by closest distance
    for (Blob blob: blobs) {
      // find min distance index
      // set the id
      Blob matchedBlob = closestNotAlreadyMatched(blob, foundBlobs);
      matchedBlob.matched = true;
      setBlob(blob, matchedBlob);
      // log("Matched blob:", blob.id);
    }

    // Now add all unmatched blobs
    for (Blob b: foundBlobs) {
      if (!b.matched) {
        addNewBlob(b);
      }
    }
  } else if (blobs.size() > foundBlobs.size()) {
    // Need to remove all that aren't there anymore
    // quickly initialize all current blobs as not matched
    for (Blob b: blobs) {
      b.matched = false;
    }

    // Reverse the loop
    for (Blob foundBlob: foundBlobs) {
      // Reverse everything!
      Blob matchedBlob = closestNotAlreadyMatched(foundBlob, blobs);

      // if it has found a match
      if (matchedBlob != null) {
        // Matched in this case is a blob we already know about
        matchedBlob.matched = true;
        matchedBlob.become(foundBlob);
        matchedBlob.resetTimer();
      }
    }

    // Now remove all unmatched
    for (int i = blobs.size() - 1; i >= 0; i--) {
      Blob blob = blobs.get(i);
      if (!blob.matched) {
        blob.decrementTimer();
        if (blob.timedout()) {
          blobs.remove(i);
          log("Goodbye blob:", blob.id);
        }
      }
    }
  }

  // how many blobs did we find?
  if (debug) {
    fill(0,150,255);
    fill(0);
    noStroke();
    text(threshold + " threshold", 20, height - 60);
    text(contours.size() + " blobs before filter", 20, height - 40);
    text(foundBlobs.size() + " blobs", 20, height - 20);
    // log(contours.size() + " blobs before filter");
    // log(foundBlobs.size() + " blobs");
  }
}
