function [firstKeypoints,firstLandmarks] = autoMonoInitialization(dataset,ransac,K,initialPose)
%function [firstState,firstLandmarks] = monocular_initialization(img0,img1,ransac,dataset)

% indicate first two images for bootstrapping
% for RANSAC filtering of matched keypoints, specify 0 (no) or 1 (yes)
% for dataset, specify 0 (kitti), 1 (malaga), or 2 (parking)

% Parameters from exercise 3.
global harris_patch_size;
global harris_kappa;
global nonmaximum_supression_radius;
global descriptor_radius;
global match_lambda;
global num_keypoints;
global triangulationTolerance;

global initializationIterations;

disp('Initializing Automatically...')

    kitti_path = 'kitti';
    malaga_path = 'malaga-urban-dataset-extract-07';
    parking_path = 'parking';
    tram_path = 'tram';

    if dataset == 0
        img0 = imread([kitti_path '/00/image_0/' ...
            sprintf('%06d.png',1)]);
    elseif dataset == 1
        images = dir([malaga_path ...
    '/malaga-urban-dataset-extract-07_rectified_800x600_Images']);
        left_images = images(3:2:end);
        img0 = rgb2gray(imread([malaga_path ...
            '/malaga-urban-dataset-extract-07_rectified_800x600_Images/' ...
            left_images(1).name]));
    elseif dataset == 2
        img0 = rgb2gray(imread([parking_path ...
            sprintf('/images/img_%05d.png',1)]));
    elseif dataset == 3
        img0 = rgb2gray(imread([tram_path ...
            sprintf('/images/scene%05d.jpg',1)]));
    else
        assert(false);
    end
    
% Find Harris scores / keypoints / descriptors of images
harris0 = harris(img0, harris_patch_size, harris_kappa);
assert(min(size(harris0) == size(img0)));
keypoints0 = selectKeypoints(harris0, num_keypoints, nonmaximum_supression_radius);
descriptors0 = describeKeypoints(img0, keypoints0, descriptor_radius);
    
max_inliers = 0;

for i=2:7

    if dataset == 0
        img1 = imread([kitti_path '/00/image_0/' ...
            sprintf('%06d.png',i)]);
    elseif dataset == 1
        img1 = rgb2gray(imread([malaga_path ...
            '/malaga-urban-dataset-extract-07_rectified_800x600_Images/' ...
            left_images(i).name]));
    elseif dataset == 2
        img1 = rgb2gray(imread([parking_path ...
            sprintf('/images/img_%05d.png',i)]));
    elseif dataset == 3
        img1 = rgb2gray(imread([tram_path ...
            sprintf('/images/scene%05d.jpg',5*(i-1)+1)]));
    else
        assert(false);
    end


%% establish keypoint correspondences between these two frames

    harris1 = harris(img1, harris_patch_size, harris_kappa);
    assert(min(size(harris1) == size(img1)));
    keypoints1 = selectKeypoints(harris1, num_keypoints, nonmaximum_supression_radius);
    descriptors1 = describeKeypoints(img1, keypoints1, descriptor_radius);


    % find all matches between the frames
    all_matches = matchDescriptors(descriptors1, descriptors0, match_lambda);
    keypoint_matches1 = flipud(keypoints1(:, all_matches > 0));

    matchesList = all_matches(all_matches > 0);
    keypoint_matches0 = flipud(keypoints0(:, matchesList));

    p0 = [keypoint_matches0; ones(1,size(keypoint_matches0,2))];
    p1 = [keypoint_matches1; ones(1,size(keypoint_matches1,2))];
   
    if(size(p0,2)>=8)
        F_candidate = fundamentalEightPoint_normalized(p0,p1);
        d = (epipolarLineDistance(F_candidate,p0,p1));
    else
        d = ones(1,size(p0,2));
    end    

    % all relevant elements on diagonal
    inlierind = find(d < triangulationTolerance);
    inliercount = length(inlierind);
    
    if inliercount>=max_inliers
        max_inliers = inliercount;
        best_p0 = p0;
        best_p1 = p1;
        best_frame = i;
    end
    
    
end

        disp(['Initializing with frame ' num2str(best_frame)])
        p0 = best_p0;
        p1 = best_p1;

%% RANSAC

    if ransac == 0
        % Estimate the essential matrix E using the 8-point algorithm
        E = estimateEssentialMatrix(p0, p1, K, K);

        % Extract the relative camera positions (R,T) from the essential matrix
        % Obtain extrinsic parameters (R,t) from E
        [Rots,u3] = decomposeEssentialMatrix(E);

        % Disambiguate among the four possible configurations
        [R_C1_W,T_C1_W] = disambiguateRelativePose(Rots,u3,p0,p1,K,K);
        %R_C1_W = Rots(:,:,2);
        %T_C1_W = u3;

        % Triangulate a point cloud using the final transformation (R,T)
        M0 = K *initialPose; % transformation from frame 0 to frame 0
        M1 = [[R_C1_W, T_C1_W];0,0,0,1]*[initialPose;0,0,0,1];
        M1 = K*M1(1:3,1:4);
        % homogeneous representation of 3D coordinates
        P = linearTriangulation(p0,p1,M0,M1);

    elseif ransac == 1
        
        k = 10; % choose k random landmarks

        % RANSAC implementation
        % use the epipolar line distance to discriminate inliers from
        % outliers; specifically: for a given candidate fundamental matrix
        % F --> a point correspondence should be considered an inlier if
        % the epipolar line distance is less than a threshold. (here 1
        % pixel)

        % Estimate the essential matrix E using the 8-point algorithm
        E = estimateEssentialMatrix(p0, p1, K, K);

        % Extract the relative camera positions (R,T) from the essential matrix
        % Obtain extrinsic parameters (R,t) from E
        [Rots,u3] = decomposeEssentialMatrix(E);

        % Disambiguate among the four possible configurations
        [R_C2_W,T_C2_W] = disambiguateRelativePose(Rots,u3,p0,p1,K,K);

        % Triangulate a point cloud using the final transformation (R,T)
        M0 = K * initialPose;
        M1 = [[R_C2_W, T_C2_W];0,0,0,1]*[initialPose;0,0,0,1];
        M1 = K*M1(1:3,1:4);
        P = linearTriangulation(p0,p1,M0,M1);

        max_num_inliers_history = zeros(1,initializationIterations+1);

        for ii = 2:initializationIterations

            % choose random data from landmarks
            [~, idx] = datasample(P(1:3,:),k,2,'Replace',false);
            p1_sample = p0(:,idx);
            p2_sample = p1(:,idx);

            % how many sample points do I need?
            % in exercise: done with landmark indices...

            F_candidate = fundamentalEightPoint_normalized(p1_sample,p2_sample);
            % E_candidate = estimateEssentialMatrix(p1_sample,p2_sample,K,K);

            % calculate epipolar line distance

            d = (epipolarLineDistance(F_candidate,p0,p1));

            % all relevant elements on diagonal
            inlierind = find(d < triangulationTolerance);
            inliercount = length(inlierind);

            if inliercount > max(max_num_inliers_history) && inliercount>=8
                max_num_inliers_history(ii) = inliercount;
                F_best = F_candidate;
            elseif inliercount <= max(max_num_inliers_history)
                % set to previous value
                max_num_inliers_history(ii) = ...
                    max_num_inliers_history(ii-1);
            end
        end
        %% COMPUTE NEW MODEL FROM BEST
        d = (epipolarLineDistance(F_best,p0,p1));
        % all relevant elements on diagonal
        inlierind = find(d < triangulationTolerance);
        p0 = p0(:,inlierind);
        p1 = p1(:,inlierind);
        % Estimate the essential matrix E using the 8-point algorithm
        E = estimateEssentialMatrix(p0, p1, K, K);
        % Extract the relative camera positions (R,T) from the essential matrix
        % Obtain extrinsic parameters (R,t) from E
        [Rots,u3] = decomposeEssentialMatrix(E);
        % Disambiguate among the four possible configurations
        [R_C2_W,T_C2_W] = disambiguateRelativePose(Rots,u3,p0,p1,K,K);
        % Triangulate a point cloud using the final transformation (R,T)
        M0 = K * initialPose;
        M1 = [[R_C2_W, T_C2_W];0,0,0,1]*[initialPose;0,0,0,1];
        M1 = K*M1(1:3,1:4);
        firstLandmarks = linearTriangulation(p0,p1,M0,M1);
        
        
        %filter new points:
        R_C_W = initialPose(1:3,1:3);
        t_C_W = initialPose(1:3,4);
        world_pose =-R_C_W'*t_C_W;
        max_dif = [ 0; 0; 0];
        min_dif = [0; 0; 0];
        
        %use in R2016b or later
        %inFront = R_C_W(3,1:3)*(firstLandmarks(1:3,:)-world_pose) > 0;
        
        % use in R2016a or earlier
        inFront = R_C_W(3,1:3)*(firstLandmarks(1:3,:)-repmat(world_pose, [1, size(firstLandmarks,2)])) > 0;
        
        PosZmax = firstLandmarks(3,:) < world_pose(3)+min_dif(3);
        PosYmax = firstLandmarks(2,:) < world_pose(2)+min_dif(2);
        PosXmax = firstLandmarks(1,:) < world_pose(1)+min_dif(1);
        
        PosZmin = firstLandmarks(3,:) > world_pose(3)+max_dif(3);
        PosYmin = firstLandmarks(2,:) > world_pose(2)+max_dif(2);
        PosXmin = firstLandmarks(1,:) > world_pose(1)+max_dif(1);
        Pos_count = PosZmax+PosYmax+PosXmax+PosZmin+PosYmin+PosXmin+inFront;
        Pok = Pos_count==4;
        firstLandmarks = firstLandmarks(:,Pok);

        disp([num2str(size(firstLandmarks,2)) ' triangulated points within bounds']) 
        
        firstKeypoints = flipud(p1(1:2,Pok));

    end
end

